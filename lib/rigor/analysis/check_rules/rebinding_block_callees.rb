# frozen_string_literal: true

require "prism"

require_relative "../dependency_recorder"
require_relative "../../inference/scope_indexer"

module Rigor
  module Analysis
    module CheckRules
      # Issue #1817 — `call.unresolved-toplevel` declines inside a block handed to a project method that may run it
      # under another `self`. `def self.define(&blk) = module_eval(&blk)` makes `Ext.define { refine(String) { … } }`
      # call `refine` on `Ext`, not on `main`, so the call is not a top-level one even though the block sits at the
      # top of the file.
      #
      # The reading is by method NAME across every project definition, never by the receiver's type: any project
      # `def` of the block's callee name that may hand the block to something else declines the rule. That
      # over-reads (an unrelated class's same-named method declines too), which only loses a report; resolving the
      # receiver would read one class and could miss the definition Ruby actually dispatches to, which reports on
      # correct code. A definition "may hand the block on" unless every use of it is provably a plain call:
      #
      # - its body only `yield`s, or reads the block parameter only as the receiver of `call` / `()` / `[]` /
      #   `yield` / `===` / `arity` / `lambda?` / `parameters` / `nil?` / `!`, or as an `if` / `unless` / `while` /
      #   `until` predicate or the left side of `&&` — each of which runs the block with its own `self` or not at
      #   all;
      # - any other read (`module_eval(&blk)`, `other(&blk)`, `@blk = blk`, `return blk`), an anonymous `&` or a
      #   `...` forwarded anywhere, a `super` that passes the block on implicitly, or a `binding` / `eval` that
      #   could reach it, may rebind `self`. Where in the body it sits does not matter: an eval under an `if` may
      #   run.
      #
      # A callee name the project gives a method without a readable `def` (`attr_*`, `alias_method`,
      # `define_method`), or patches through `pre_eval:`, cannot be read and declines too. So does a `send` /
      # `__send__` / `public_send` whose method name is not a literal. A callee no project file defines keeps the
      # rule's old answer: Rigor reads only the project's own bodies here.
      module RebindingBlockCallees
        SEND_CALLS = %i[send __send__ public_send].freeze
        # Reading the block through these runs it with its own `self`, or does not run it.
        PLAIN_PROC_CALLS = %i[call yield [] === ! arity lambda? parameters nil?].freeze
        # Receiverless calls that can reach a local by name.
        BINDING_CALLS = %i[binding eval].freeze
        PREDICATE_PARENTS = [Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode].freeze
        # `proc { … }`, `lambda { … }` and `Proc.new { … }` passed with `&` are the block of the call they go to.
        PROC_LITERAL_CALLS = %i[proc lambda].freeze
        private_constant :SEND_CALLS, :PLAIN_PROC_CALLS, :BINDING_CALLS, :PREDICATE_PARENTS, :PROC_LITERAL_CALLS

        # The calls in one file that pass a literal block, each with the offsets that block's body spans, plus the
        # file's memo of callee answers. Built on the first ask, so a file whose would-fire calls all decline earlier
        # never walks. One file is one ADR-46 consumer, so an answer's dependency edges, recorded on its first ask,
        # hold for every later call in the file that reuses it.
        class Sites
          attr_reader :answers

          def initialize(root)
            @root = root
            @rows = nil
            @answers = {}
            @def_rows = nil
          end

          # The block-passing calls whose block contains `node`. Rows are in start order, so the scan stops at the
          # first block that starts after `node`.
          def enclosing(node)
            build
            start = node.location.start_offset
            stop = node.location.end_offset
            found = []
            @rows.each do |from, to, call|
              break if from > start

              found << call if stop <= to
            end
            found
          end

          # `{name => {[owner, side] => rows}}` over the project's named `def` rows, built once per file.
          def def_rows(scope)
            @def_rows ||= RebindingBlockCallees.def_row_counts(scope)
          end

          private

          def build
            return if @rows

            @rows = []
            collect(@root) unless @root.nil?
          end

          def collect(node)
            if node.is_a?(Prism::CallNode)
              body = RebindingBlockCallees.block_body(node.block)
              @rows << [body.location.start_offset, body.location.end_offset, node] if body
            end
            node.compact_child_nodes.each { |child| collect(child) }
          end
        end

        module_function

        # Does `call_node` sit inside a block that some project definition of its callee may run under another `self`?
        def inside_rebound_block?(call_node, scope, sites)
          sites.enclosing(call_node).any? { |block_call| callee_may_rebind?(block_call, scope, sites) }
        end

        # The node whose span is the block `call` passes: its literal block, or a lambda / proc literal passed with `&`.
        def block_body(block)
          case block
          when Prism::BlockNode then block
          when Prism::BlockArgumentNode then proc_literal(block.expression)
          end
        end

        def proc_literal(node)
          case node
          when Prism::LambdaNode then node
          when Prism::CallNode
            node.block if node.block.is_a?(Prism::BlockNode) && proc_literal_call?(node)
          end
        end

        def proc_literal_call?(node)
          return PROC_LITERAL_CALLS.include?(node.name) if node.receiver.nil?

          node.name == :new && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Proc
        end

        def callee_may_rebind?(block_call, scope, sites)
          name = callee_name(block_call)
          return true if name.nil?

          answers = sites.answers
          return answers[name] if answers.key?(name)

          answers[name] = project_may_rebind?(name, scope, sites)
        end

        # The method the block reaches: the call's own name, or the literal name a `send` family call dispatches to.
        # nil when a `send` names its method with anything but a literal, or with a String that is no valid name.
        def callee_name(call)
          return call.name unless SEND_CALLS.include?(call.name)

          first = call.arguments&.arguments&.first
          case first
          when Prism::SymbolNode, Prism::StringNode
            text = first.unescaped
            text.to_sym if text.valid_encoding?
          end
        end

        # Reads every project table for `name`, so it records a `defines:<name>` edge whichever way it answers (a file
        # that starts or stops defining the name re-checks this one), plus each read body's own method edge through the
        # scope accessors (an edit of that body re-checks this one).
        def project_may_rebind?(name, scope, sites)
          DependencyRecorder.read_missing(:defines, name) if DependencyRecorder.active?
          return true if patched_anywhere?(name, scope)

          slots = Set.new
          readers = {
            [scope.discovered_def_nodes, :instance] => ->(owner) { instance_def(scope, owner, name) },
            [scope.discovered_singleton_def_nodes, :singleton] => ->(owner) { scope.singleton_def_for(owner, name) }
          }
          readers.each do |(tables, side), reader|
            tables.each do |owner, table|
              next unless table.key?(name)

              slots << [owner, side]
              node = reader.call(owner)
              return true if !node.is_a?(Prism::DefNode) || def_may_rebind?(node)
            end
          end
          unread_definition?(sites.def_rows(scope)[name], slots) || bodiless_definition?(name, scope)
        end

        def instance_def(scope, owner, name)
          return scope.top_level_def_for(name) if owner == Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY

          scope.user_def_for(owner, name)
        end

        # A def table keeps one body per class and side, so a second `def` of the name for the same slot (in a
        # sibling file, whose order is not load order, or in the other arm of an `if`) is one the tables never
        # showed, and so is a `def` whose class and side the tables hold no slot for. Every `def` outside a deferred
        # body has a named row in the deferred-range table; a `module_function` row stands for both sides.
        def unread_definition?(rows, slots)
          return false if rows.nil?

          rows.any? { |slot, count| count > 1 || !slots.include?(slot) }
        end

        def def_row_counts(scope)
          counts = Hash.new { |hash, name| hash[name] = Hash.new(0) }
          scope.discovered_deferred_ranges.each_value do |list|
            list.each do |(_start, _stop, name, kind, owner)|
              next if name.nil?

              key = owner || Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY
              sides = kind == :both ? %i[instance singleton] : [kind]
              sides.each { |side| counts[name][[key, side]] += 1 }
            end
          end
          counts.default_proc = nil
          counts
        end

        # A name some class gives a method with no `def` body Rigor holds (`attr_*`, `alias_method`, `define_method`).
        def bodiless_definition?(name, scope)
          scope.discovered_methods.any? do |owner, table|
            table.key?(name) &&
              !scope.discovered_def_nodes[owner]&.key?(name) &&
              !scope.discovered_singleton_def_nodes[owner]&.key?(name)
          end
        end

        def patched_anywhere?(name, scope)
          patched = scope.environment&.project_patched_methods
          !patched.nil? && patched.by_key.any? { |(_owner, patched_name, _kind), _entry| patched_name == name }
        end

        def def_may_rebind?(def_node)
          return false if def_node.body.nil?

          block = def_node.parameters&.block
          escapes?(def_node.body, nil, block&.name)
        end

        # `block_name` is the def's named `&` parameter, or nil.
        def escapes?(node, parent, block_name)
          return true if hands_block_on?(node, parent, block_name)

          node.compact_child_nodes.any? { |child| escapes?(child, node, block_name) }
        end

        def hands_block_on?(node, parent, block_name)
          case node
          when Prism::ForwardingSuperNode then !node.block.is_a?(Prism::BlockNode)
          when Prism::SuperNode then node.block.nil?
          when Prism::BlockArgumentNode then node.expression.nil?
          when Prism::ForwardingArgumentsNode then true
          when Prism::LocalVariableReadNode then node.name == block_name && !plain_read?(node, parent)
          when Prism::CallNode then node.receiver.nil? && BINDING_CALLS.include?(node.name)
          else false
          end
        end

        def plain_read?(node, parent)
          case parent
          when Prism::CallNode then parent.receiver.equal?(node) && PLAIN_PROC_CALLS.include?(parent.name)
          when Prism::AndNode then parent.left.equal?(node)
          when *PREDICATE_PARENTS then parent.predicate.equal?(node)
          else false
          end
        end
      end
    end
  end
end
