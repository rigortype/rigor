# frozen_string_literal: true

require "prism"

require_relative "../../inference/scope_indexer"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # Issue #1120 — the two ways one file makes a method callable at some sites and not at others, which
      # `call.undefined-method` has to ask the file's syntax about because no project-wide table can answer:
      #
      # - **Refinements.** `using M` activates M's refinements from the end of the call to the end of the body
      #   that holds it — the file's top level or a `class` / `module` body, including everything nested in it —
      #   and nowhere else, not even in another file. A `refine X do … end` block is active inside itself. What
      #   each module refines is the project-wide `Scope#discovered_refinements`; this answers whether any of
      #   those modules is in effect at a call site. A `using` whose argument is not a constant
      #   (`using Module.new { refine … }`) names no module, so every refinement counts as in effect throughout
      #   its file. A `using` inside a `def` raises in Ruby and activates nothing.
      # - **Singleton defs on locals.** `def o.m` defines `m` on the one object `o` holds. The local's type
      #   is not changed; `o.m` is simply not reported within the scope the `def` is written in (the
      #   enclosing `def`, `class` / `module` body, or file — a block shares its enclosing scope's locals).
      #
      # Built lazily: the walk runs the first time a would-fire call asks, so a file with no such call pays
      # one small object and nothing else.
      class LexicalMethodSites
        def initialize(root)
          @root = root
          @built = false
        end

        # Is a refinement from one of `modules` (refining-module names) in effect at `call_node`?
        def refinement_active?(call_node, modules)
          build
          return true if @unresolved_using

          offset = call_node.location.start_offset
          return true if @refine_blocks.any? { |start, stop| offset >= start && offset < stop }

          @usings.any? do |start, stop, candidates|
            offset >= start && offset < stop && candidates.any? { |name| modules.include?(name) }
          end
        end

        # Issue #1367 — is any refinement in effect at `node`: a `using` of any module, a `using` of a non-constant, or
        # the inside of a `refine` block? The `global.*` stream check asks it where it cannot name the refining
        # module (a `define_method` or `alias_method` inside `refine` records none).
        def using_in_effect?(node)
          build
          return true if @unresolved_using

          offset = node.location.start_offset
          @refine_blocks.any? { |start, stop| offset >= start && offset < stop } ||
            @usings.any? { |start, stop, _candidates| offset >= start && offset < stop }
        end

        # Is `def_node` one of the defs a `refine X do … end` body defines on X? Such a def redefines X's method by
        # design, so X's declared signature for the name is not its contract (issue #1120, maintainer ruling a′).
        def refinement_def?(def_node)
          build
          @refinement_defs.include?(def_node.location.start_offset)
        end

        # Does a `def <local>.<name>` for this call's local receiver and method name sit in the scope the call
        # is in?
        def singleton_local_def?(call_node)
          receiver = call_node.receiver
          return false unless receiver.is_a?(Prism::LocalVariableReadNode)

          build
          offset = call_node.location.start_offset
          @singleton_defs.any? do |local, method_name, start, stop|
            local == receiver.name && method_name == call_node.name && offset >= start && offset < stop &&
              !nested_scope_holds?(offset, start, stop)
          end
        end

        private

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
          @usings = []
          @refine_blocks = []
          @singleton_defs = []
          @scopes = []
          @refinement_defs = Set.new
          @unresolved_using = false
          return if @root.nil?

          location = @root.location
          span = [location.start_offset, location.end_offset]
          walk(@root, [], span, span, false)
        end

        # `body` is the `[start, end]` of the body a `using` here stays in effect to the end of; `locals` is the
        # span of the scope a local written here belongs to.
        def walk(node, prefix, body, locals, in_def)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            span = scope_span(node)
            inner = Source::ConstantPath.declaration_prefix(prefix, node.constant_path) || prefix
            return walk_children(node.body, inner, span, span, false)
          when Prism::SingletonClassNode
            walk(node.expression, prefix, body, locals, in_def)
            span = scope_span(node)
            return walk_children(node.body, prefix, span, span, false)
          when Prism::DefNode
            record_singleton_def(node, locals)
            return walk_children(node.body, prefix, body, scope_span(node), true)
          when Prism::CallNode
            record_call(node, prefix, body, in_def)
          end

          walk_children(node, prefix, body, locals, in_def)
        end

        def walk_children(node, prefix, body, locals, in_def)
          return if node.nil?

          node.rigor_each_child { |child| walk(child, prefix, body, locals, in_def) }
        end

        def record_singleton_def(node, locals)
          receiver = node.receiver
          return unless receiver.is_a?(Prism::LocalVariableReadNode)

          @singleton_defs << [receiver.name, node.name, *locals]
        end

        def record_call(node, prefix, body, in_def)
          if Inference::ScopeIndexer.refine_target(node)
            @refine_blocks << span_of(node.block)
            record_refinement_defs(node.block.body)
          elsif using_call?(node) && !in_def
            record_using(node, prefix, body)
          end
        end

        def record_refinement_defs(body)
          return if body.nil?

          Inference::ScopeIndexer.each_refinement_def(body) do |def_node|
            @refinement_defs << def_node.location.start_offset
          end
        end

        def using_call?(node)
          node.name == :using && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
            node.arguments&.arguments&.size == 1
        end

        def record_using(node, prefix, body)
          argument = node.arguments.arguments.first
          if argument.is_a?(Prism::ConstantReadNode) || argument.is_a?(Prism::ConstantPathNode)
            candidates = Inference::ScopeIndexer.constant_receiver_candidates(argument, prefix)
            @usings << [node.location.end_offset, body.last, candidates]
          else
            @unresolved_using = true
          end
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
