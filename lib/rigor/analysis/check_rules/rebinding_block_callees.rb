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
      # `define_method`, `define_singleton_method` on any receiver, a `def` written inside a block), or patches
      # through `pre_eval:`, cannot be read and declines too. So does a `send` / `__send__` / `public_send` whose
      # method name is not a literal. Issue #2184 — a project `method_missing` that may hand its block on answers
      # for every name, since Ruby reaches it for any name the receiver lacks; and the block of a `define_method` /
      # `define_singleton_method` call is a method body, run under whatever receives the method. A callee no project
      # file defines keeps the rule's old answer otherwise: Rigor reads only the project's own bodies here.
      module RebindingBlockCallees
        SEND_CALLS = %i[send __send__ public_send].freeze
        # Reading the block through these runs it with its own `self`, or does not run it.
        PLAIN_PROC_CALLS = %i[call yield [] === ! arity lambda? parameters nil?].freeze
        # Calls, on any receiver, that can reach a local by name: a `Binding`, a string `eval`, and the string forms of
        # the `*_eval` family (with an argument), whose code runs in the caller's scope.
        BINDING_CALLS = %i[binding eval local_variable_get].freeze
        STRING_EVAL_CALLS = %i[instance_eval class_eval module_eval].freeze
        private_constant :STRING_EVAL_CALLS
        PREDICATE_PARENTS = [Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode].freeze
        # `proc { … }`, `lambda { … }` and `Proc.new { … }` passed with `&` are the block of the call they go to.
        PROC_LITERAL_CALLS = %i[proc lambda].freeze
        # Core methods that run their block under another `self`: as a method body, or under the receiver (#2186:
        # also when the block is a proc passed through a local, `Ext.instance_exec(&blk)`).
        REBINDING_CORE_CALLS = %i[
          define_method define_singleton_method
          instance_eval instance_exec class_eval class_exec module_eval module_exec
        ].freeze
        private_constant :REBINDING_CORE_CALLS
        private_constant :SEND_CALLS, :PLAIN_PROC_CALLS, :BINDING_CALLS, :PREDICATE_PARENTS, :PROC_LITERAL_CALLS

        # The calls in one file that pass a literal block, each with the offsets that block's body spans, plus the
        # file's memo of callee answers. Built on the first ask, so a file whose would-fire calls all decline earlier
        # never walks. One file is one ADR-46 consumer, so an answer's dependency edges, recorded on its first ask,
        # hold for every later call in the file that reuses it.
        #
        # Issue #2186 — a proc literal that is a value rather than a call's block (`blk = proc { … }`) adds a row for
        # each call that receives it as `&blk`, when every other read of that local only calls or tests it. A literal
        # called in place (`proc { … }.call`) runs with its own `self` and adds none. Any other proc value (stored,
        # passed positionally, read another way, or in a method (or the code around it) that may read locals by name
        # through `binding` / `eval` / `local_variable_get` or a computed `send`) cannot be followed to the call that
        # runs it, so its row is {UNKNOWN}, which declines. A heredoc that opens inside a block adds a row over its
        # body: Prism puts the body after the block's closing brace, but Ruby runs its interpolation inside the block.
        class Sites
          # The target of a row whose block Rigor cannot follow to the call that runs it.
          UNKNOWN = :unknown

          attr_reader :answers

          def initialize(root)
            @root = root
            @rows = nil
            @answers = {}
            @def_rows = nil
          end

          # The block-passing calls (or {UNKNOWN}) whose block contains `node`. Rows are sorted by start, so the scan
          # stops at the first block that starts after `node`.
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
            @bodies = []
            @heredocs = []
            @proc_values = []
            @local_reads = Hash.new { |hash, name| hash[name] = [] }
            @block_passes = Hash.new { |hash, name| hash[name] = [] }
            @scopes_reading_locals = Set.new.compare_by_identity
            walk unless @root.nil?
            # A block call chained on another (`m { }.then { }`) is met after the call whose block starts later.
            @rows.sort_by!(&:first)
          end

          def walk
            collect(@root, nil, @root)
            @proc_values.each do |body, parent, local_scope|
              value_targets(parent, local_scope).each { |target| @bodies << [body, target] }
            end
            @heredocs.sort_by!(&:first)
            @bodies.each { |body, target| add_rows(body, target) }
          end

          def collect(node, parent, local_scope)
            heredoc = RebindingBlockCallees.heredoc_range(node)
            @heredocs << heredoc if heredoc
            note(node, parent, local_scope)
            # A `def` opens a new local-variable scope; blocks and lambdas share the enclosing one. A class body is
            # read as part of the scope around it, which only widens the set a `binding` there may reach.
            inner = node.is_a?(Prism::DefNode) ? node : local_scope
            node.compact_child_nodes.each { |child| collect(child, node, inner) }
          end

          def note(node, parent, local_scope)
            case node
            when Prism::CallNode then note_call(node, parent, local_scope)
            when Prism::LambdaNode then note_value(node, node, parent, local_scope)
            when Prism::LocalVariableReadNode
              @local_reads[node.name] << [node, parent] unless parent.is_a?(Prism::BlockArgumentNode)
            end
          end

          def note_call(node, parent, local_scope)
            block = node.block
            body = RebindingBlockCallees.block_body(block)
            @bodies << [body, node] if body
            if block.is_a?(Prism::BlockArgumentNode) && block.expression.is_a?(Prism::LocalVariableReadNode)
              @block_passes[block.expression.name] << node
            end
            value = RebindingBlockCallees.proc_literal(node)
            note_value(node, value, parent, local_scope) if value
            target = RebindingBlockCallees.send_target(node)
            @scopes_reading_locals << local_scope if target.nil? || BINDING_CALLS.include?(target)
          end

          # `literal` is the proc expression and `body` its block. Passed with `&`, it is that call's block.
          def note_value(literal, body, parent, local_scope)
            return if parent.is_a?(Prism::BlockArgumentNode) || RebindingBlockCallees.plain_read?(literal, parent)

            @proc_values << [body, parent, local_scope]
          end

          # The calls a proc value assigned to a local reaches as `&local`, or {UNKNOWN}.
          def value_targets(parent, local_scope)
            return [UNKNOWN] if @scopes_reading_locals.include?(local_scope)
            return [UNKNOWN] unless parent.is_a?(Prism::LocalVariableWriteNode)

            name = parent.name
            followed = @local_reads[name].all? do |read, read_parent|
              RebindingBlockCallees.plain_read?(read, read_parent)
            end
            followed ? @block_passes[name] : [UNKNOWN]
          end

          # The block's own row, plus one over the body of each heredoc that opens inside it.
          def add_rows(body, target)
            from = body.location.start_offset
            to = body.location.end_offset
            @rows << [from, to, target]
            index = @heredocs.bsearch_index { |(opening, _start, _stop)| opening >= from }
            return if index.nil?

            while index < @heredocs.size && @heredocs[index].first < to
              _opening, start, stop = @heredocs[index]
              @rows << [start, stop, target]
              index += 1
            end
          end
        end

        module_function

        # Does `call_node` sit inside a block that some project definition of its callee may run under another `self`?
        def inside_rebound_block?(call_node, scope, sites, scope_index = nil)
          sites.enclosing(call_node).any? do |block_call|
            block_call == Sites::UNKNOWN || callee_may_rebind?(block_call, scope, sites, scope_index)
          end
        end

        # `[opening, body start, end]` offsets of a heredoc `node` opens, or nil.
        def heredoc_range(node)
          opening = node.opening_loc if node.respond_to?(:opening_loc)
          closing = node.closing_loc if node.respond_to?(:closing_loc)
          return nil unless opening&.slice&.start_with?("<<") && closing

          start = case node
                  when Prism::StringNode, Prism::XStringNode then node.content_loc.start_offset
                  when Prism::InterpolatedStringNode, Prism::InterpolatedXStringNode
                    node.parts.first&.location&.start_offset
                  end
          [opening.start_offset, start || closing.start_offset, closing.end_offset]
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

        def callee_may_rebind?(block_call, scope, sites, scope_index = nil)
          name, receiver = Dispatch.dispatch(block_call)
          return true if name.nil? || REBINDING_CORE_CALLS.include?(name)
          return true if Dispatch.callable_call?(name, receiver, scope, scope_index)
          return true if answer(name, scope, sites)
          # Ruby reaches `method_missing` only for a name the receiver lacks.
          return false if Dispatch.resolves_on_receiver?(receiver, name, scope, scope_index)

          answer(:method_missing, scope, sites)
        end

        def answer(name, scope, sites)
          answers = sites.answers
          return answers[name] if answers.key?(name)

          answers[name] = project_may_rebind?(name, scope, sites)
        end

        # The call's own name, or the literal name a `send` family call dispatches to (nil when it is not one).
        def send_target(call)
          return call.name unless SEND_CALLS.include?(call.name)

          literal_name(call.arguments&.arguments&.first)
        end

        def literal_name(first)
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
        # body has a named row in the deferred-range table; a `module_function` row stands for both sides. A row with
        # no side (a `def` inside a block, a `define_singleton_method` name) counts under a nil side, which no slot has.
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
          when Prism::CallNode then reaches_locals?(node)
          else false
          end
        end

        # Issue #2186 — a call that can reach the block local by name, on any receiver and through `send`:
        # `Kernel.eval("module_eval(&b)")`, `send(:binding).local_variable_get(:b)`, `instance_eval("module_eval(&b)")`.
        # A `send` whose method name is not a literal may be any of them.
        def reaches_locals?(call)
          name = send_target(call)
          return true if name.nil? || BINDING_CALLS.include?(name)

          STRING_EVAL_CALLS.include?(name) && !call.arguments.nil?
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

require_relative "rebinding_block_callees/dispatch"
