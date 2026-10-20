# frozen_string_literal: true

require "prism"

require_relative "../../inference/scope_indexer"
require_relative "../../source/node_children"
require_relative "rebinding_block_callees"

module Rigor
  module Analysis
    module CheckRules
      # Issue #1120 — the two ways one file makes a method callable at some sites and not at others, which
      # `call.undefined-method` has to ask the file's syntax about because no project-wide table can answer:
      #
      # - **Refinements.** Issue #1673 — answered by the file's in-effect refinements ({#refinements}, the
      #   {Inference::InEffectRefinements} the typer reads too); the rules ask it for derived answers
      #   (`refinement_active?`, `any_at?`, `refinement_def?`).
      # - **Singleton defs on locals.** `def o.m` defines `m` on the one object `o` holds. The local's type
      #   is not changed; `o.m` is simply not reported within the scope the `def` is written in (the
      #   enclosing `def`, `class` / `module` body, or file — a block shares its enclosing scope's locals).
      #   Issue #1722 — the other spellings that give that one object methods make the local opaque for every
      #   name in the same scope: `o.extend(M)`, `o.define_singleton_method(...)` (only the literal name it
      #   defines, when it names one), any call on `o.singleton_class` (`class_eval { def m }`, `define_method`,
      #   `include`), `class << o`, and an `o.instance_eval` / `o.instance_exec` that is given a String or whose
      #   block writes a `def` or calls `extend` / `define_singleton_method`. Where in the scope the call sits,
      #   and whether it runs, are not read: a call under an `if` may run. A local assigned `o.clone` shares
      #   what `o` has (`clone` copies the singleton class, `dup` does not).
      #
      # Built lazily: the walk runs the first time a would-fire call asks, so a file with no such call pays
      # one small object and nothing else.
      class LexicalMethodSites
        # Issue #1703 — the file's root, which `call.possible-nil-receiver` re-walks for a `key?` guard.
        attr_reader :root

        # `refinements` is the query `Inference::ScopeIndexer` stamped on the file's discovery index, so the rules and
        # the typer share one walk; a query over another tree, or none, builds this file's own on the first ask.
        def initialize(root, refinements = nil)
          @root = root
          @built = false
          @refinements = refinements if refinements&.over?(root)
        end

        def refinements = (@refinements ||= Inference::InEffectRefinements.new(@root))

        # Issue #1817 — the file's block-passing calls, for `call.unresolved-toplevel`'s rebinding-callee decline.
        def block_calls = (@block_calls ||= RebindingBlockCallees::Sites.new(@root))

        # Does a `def <local>.<name>` for this call's local receiver and method name — or a call that gives the
        # local's object methods Rigor does not enumerate (issue #1722) — sit in the scope the call is in?
        def singleton_local_def?(call_node)
          receiver = call_node.receiver
          return false unless receiver.is_a?(Prism::LocalVariableReadNode)

          build
          singleton_local_holds?(receiver.name, call_node.name, call_node.location.start_offset, CLONE_DEPTH)
        end

        # The name an opening records when it may define any method on the local's object.
        ANY_METHOD = Object.new.freeze
        # How many `t = s.clone` links a lookup follows.
        CLONE_DEPTH = 4
        EVAL_CALLS = %i[instance_eval instance_exec].freeze
        EVAL_BLOCK_CALLS = %i[extend define_singleton_method].freeze
        private_constant :ANY_METHOD, :CLONE_DEPTH, :EVAL_CALLS, :EVAL_BLOCK_CALLS

        private

        def singleton_local_holds?(local_name, method_name, offset, depth)
          opened = in_scope?(@singleton_defs, offset) do |local, name|
            local == local_name && (name.equal?(ANY_METHOD) || name == method_name)
          end
          return true if opened
          return false if depth.zero?

          @clones.any? do |target, source, start, stop|
            target == local_name && offset >= start && offset < stop && !nested_scope_holds?(offset, start, stop) &&
              singleton_local_holds?(source, method_name, offset, depth - 1)
          end
        end

        def in_scope?(rows, offset)
          rows.any? do |local, name, start, stop|
            yield(local, name) && offset >= start && offset < stop && !nested_scope_holds?(offset, start, stop)
          end
        end

        # Is `offset` inside a local scope nested in the one `[start, stop)` spans? A `def` in the file's top level
        # does not see the top level's `o`.
        def nested_scope_holds?(offset, start, stop)
          @scopes.any? do |inner_start, inner_stop|
            (inner_start > start || inner_stop < stop) && inner_start >= start && inner_stop <= stop &&
              offset >= inner_start && offset < inner_stop
          end
        end

        def build
          return if @built

          @built = true
          @singleton_defs = []
          @clones = []
          @scopes = []
          return if @root.nil?

          location = @root.location
          span = [location.start_offset, location.end_offset]
          walk(@root, span)
        end

        # `locals` is the span of the scope a local written here belongs to.
        def walk(node, locals)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            return walk_children(node.body, scope_span(node))
          when Prism::SingletonClassNode
            record_opened_local(node.expression, ANY_METHOD, locals)
            walk(node.expression, locals)
            return walk_children(node.body, scope_span(node))
          when Prism::DefNode
            record_singleton_def(node, locals)
            return walk_children(node.body, scope_span(node))
          when Prism::CallNode
            record_singleton_opening(node, locals)
          when Prism::LocalVariableWriteNode
            record_clone(node, locals)
          end

          walk_children(node, locals)
        end

        def walk_children(node, locals)
          return if node.nil?

          node.rigor_each_child { |child| walk(child, locals) }
        end

        def record_singleton_def(node, locals)
          receiver = node.receiver
          return unless receiver.is_a?(Prism::LocalVariableReadNode)

          @singleton_defs << [receiver.name, node.name, *locals]
        end

        # Issue #1722 — a call that gives the object its receiver local holds singleton methods.
        def record_singleton_opening(node, locals)
          receiver = node.receiver
          if singleton_class_of_local?(receiver)
            record_opened_local(receiver.receiver, ANY_METHOD, locals)
          elsif receiver.is_a?(Prism::LocalVariableReadNode)
            name = opened_method_name(node)
            record_opened_local(receiver, name, locals) if name
          end
        end

        # `o.singleton_class`.
        def singleton_class_of_local?(node)
          node.is_a?(Prism::CallNode) && node.name == :singleton_class && node.arguments.nil? &&
            node.receiver.is_a?(Prism::LocalVariableReadNode)
        end

        # The method name a call on a local defines on the local's object: the literal name given to
        # `define_singleton_method`, {ANY_METHOD} where it may be any name, or nil when the call defines none.
        def opened_method_name(node)
          case node.name
          when :extend then ANY_METHOD
          when :define_singleton_method then literal_name(node.arguments&.arguments&.first) || ANY_METHOD
          when *EVAL_CALLS then ANY_METHOD if eval_defines?(node)
          end
        end

        def literal_name(node)
          node.unescaped.to_sym if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
        end

        # An `instance_eval` given code as a String, or whose block writes a `def` or calls `extend` /
        # `define_singleton_method` on its `self`.
        def eval_defines?(node)
          return true unless node.arguments.nil?

          block = node.block
          block.is_a?(Prism::BlockNode) && defines_on_self?(block.body)
        end

        def defines_on_self?(node)
          return false if node.nil?
          return true if node.is_a?(Prism::DefNode)
          if node.is_a?(Prism::CallNode) && EVAL_BLOCK_CALLS.include?(node.name) &&
             (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
            return true
          end

          found = false
          node.rigor_each_child { |child| found ||= defines_on_self?(child) }
          found
        end

        def record_opened_local(node, method_name, locals)
          return unless node.is_a?(Prism::LocalVariableReadNode)

          @singleton_defs << [node.name, method_name, *locals]
        end

        # `t = s.clone`: `clone` copies the singleton class, so `t` holds what `s` was given.
        def record_clone(node, locals)
          value = node.value
          return unless value.is_a?(Prism::CallNode) && value.name == :clone
          return unless value.receiver.is_a?(Prism::LocalVariableReadNode)

          @clones << [node.name, value.receiver.name, *locals]
        end

        # The span of a node that opens a local scope, recorded for {#nested_scope_holds?}.
        def scope_span(node)
          span = span_of(node)
          @scopes << span
          span
        end

        def span_of(node)
          location = node.location
          [location.start_offset, location.end_offset]
        end
      end
    end
  end
end
