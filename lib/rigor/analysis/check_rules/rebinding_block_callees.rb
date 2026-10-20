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
        # Issue #2186 — a block given to `call` / `()` / `bind_call` on a Method object goes to the method it names:
        # `Ext.method(:me).call { … }` is `Ext.me { … }`.
        METHOD_OBJECT_CALLS = %i[call yield === [] bind_call].freeze
        METHOD_READERS = %i[method public_method singleton_method instance_method public_instance_method].freeze
        METHOD_WRAPPERS = %i[bind unbind to_proc curry].freeze
        private_constant :STRING_EVAL_CALLS, :METHOD_OBJECT_CALLS, :METHOD_READERS, :METHOD_WRAPPERS
        PREDICATE_PARENTS = [Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode].freeze
        # `proc { … }`, `lambda { … }` and `Proc.new { … }` passed with `&` are the block of the call they go to.
        PROC_LITERAL_CALLS = %i[proc lambda].freeze
        # Core methods whose block becomes a method body, run under the method's receiver.
        METHOD_BODY_BLOCK_CALLS = %i[define_method define_singleton_method].freeze
        private_constant :METHOD_BODY_BLOCK_CALLS
        private_constant :SEND_CALLS, :PLAIN_PROC_CALLS, :BINDING_CALLS, :PREDICATE_PARENTS, :PROC_LITERAL_CALLS

        # The calls in one file that pass a literal block, each with the offsets that block's body spans, plus the
        # file's memo of callee answers. Built on the first ask, so a file whose would-fire calls all decline earlier
        # never walks. One file is one ADR-46 consumer, so an answer's dependency edges, recorded on its first ask,
        # hold for every later call in the file that reuses it.
        #
        # Issue #2186 — a proc literal that is a value rather than a call's block (`blk = proc { … }`) adds a row for
        # each call that receives it as `&blk`, when every other read of that local only calls or tests it. Any other
        # proc value (stored, passed positionally, read another way, or in a file that may read locals by name through
        # `binding` / `eval` / `local_variable_get` or a computed `send`) cannot be followed to the call that runs it,
        # so its row is {UNKNOWN}, which declines. A block's span runs to the end of the last heredoc that opens inside
        # it: Prism puts a heredoc's body after the block's closing brace, but Ruby runs its interpolation inside the
        # block.
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
            @heredoc_ends = {}.compare_by_identity
            @proc_values = []
            @local_reads = Hash.new { |hash, name| hash[name] = [] }
            @block_passes = Hash.new { |hash, name| hash[name] = [] }
            @reads_locals_by_name = false
            unless @root.nil?
              collect(@root, nil)
              @proc_values.each { |body, parent| value_targets(parent).each { |target| add_row(body, target) } }
            end
            # A block call chained on another (`m { }.then { }`) is met after the call whose block starts later.
            @rows.sort_by!(&:first)
          end

          # Walks children first and answers the end offset of the last heredoc that opens in `node`'s subtree.
          def collect(node, parent)
            last = RebindingBlockCallees.heredoc_end(node)
            node.compact_child_nodes.each do |child|
              child_end = collect(child, node)
              last = child_end if child_end && (last.nil? || child_end > last)
            end
            @heredoc_ends[node] = last if last
            note(node, parent)
            last
          end

          def note(node, parent)
            case node
            when Prism::CallNode then note_call(node, parent)
            when Prism::LambdaNode then @proc_values << [node, parent] unless parent.is_a?(Prism::BlockArgumentNode)
            when Prism::LocalVariableReadNode
              @local_reads[node.name] << [node, parent] unless parent.is_a?(Prism::BlockArgumentNode)
            end
          end

          def note_call(node, parent)
            block = node.block
            body = RebindingBlockCallees.block_body(block)
            add_row(body, node) if body
            if block.is_a?(Prism::BlockArgumentNode) && block.expression.is_a?(Prism::LocalVariableReadNode)
              @block_passes[block.expression.name] << node
            end
            value = RebindingBlockCallees.proc_literal(node)
            @proc_values << [value, parent] if value && !parent.is_a?(Prism::BlockArgumentNode)
            target = RebindingBlockCallees.send_target(node)
            @reads_locals_by_name = true if target.nil? || BINDING_CALLS.include?(target)
          end

          # The calls a proc value assigned to a local reaches as `&local`, or {UNKNOWN}.
          def value_targets(parent)
            return [UNKNOWN] if @reads_locals_by_name || !parent.is_a?(Prism::LocalVariableWriteNode)

            name = parent.name
            followed = @local_reads[name].all? do |read, read_parent|
              RebindingBlockCallees.plain_read?(read, read_parent)
            end
            followed ? @block_passes[name] : [UNKNOWN]
          end

          def add_row(body, target)
            stop = body.location.end_offset
            heredoc = @heredoc_ends[body]
            @rows << [body.location.start_offset, heredoc && heredoc > stop ? heredoc : stop, target]
          end
        end

        module_function

        # Does `call_node` sit inside a block that some project definition of its callee may run under another `self`?
        def inside_rebound_block?(call_node, scope, sites, scope_index = nil)
          sites.enclosing(call_node).any? do |block_call|
            block_call == Sites::UNKNOWN || callee_may_rebind?(block_call, scope, sites, scope_index)
          end
        end

        # The end offset of a heredoc `node` opens, or nil.
        def heredoc_end(node)
          case node
          when Prism::StringNode, Prism::InterpolatedStringNode, Prism::XStringNode, Prism::InterpolatedXStringNode
            closing = node.closing_loc
            closing.end_offset if closing && node.opening_loc&.slice&.start_with?("<<")
          end
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
          name = callee_name(block_call)
          return true if name.nil? || METHOD_BODY_BLOCK_CALLS.include?(name)
          return true if answer(name, scope, sites)
          # Ruby reaches `method_missing` only for a name the receiver lacks.
          return false if resolves_on_receiver?(block_call, name, scope, scope_index)

          answer(:method_missing, scope, sites)
        end

        # Whether the receiver's type names a class whose RBS or project table gives it `name`, on every member of a
        # union. A receiverless call at the top level asks `Object`, `main`'s class. Any other type cannot say.
        def resolves_on_receiver?(block_call, name, scope, scope_index)
          receiver = block_call.receiver
          return scope.toplevel? && class_defines?("Object", :instance, name, scope) if receiver.nil?

          receiver_scope = scope_index&.[](receiver) || scope
          type_resolves?(receiver_scope.type_of(receiver), name, scope)
        rescue StandardError
          false
        end

        def type_resolves?(type, name, scope)
          case type
          when Type::Union then type.members.all? { |member| type_resolves?(member, name, scope) }
          when Type::Singleton then class_defines?(type.class_name, :singleton, name, scope)
          else
            class_name = receiver_class_name(type)
            !class_name.nil? && class_defines?(class_name, :instance, name, scope)
          end
        end

        def receiver_class_name(type)
          case type
          when Type::Nominal, Type::StructInstance, Type::DataInstance then type.class_name&.to_s
          when Type::Tuple then "Array"
          when Type::HashShape then "Hash"
          when Type::Constant then type.value.class.name
          end
        end

        def class_defines?(class_name, side, name, scope)
          rbs = if side == :singleton
                  Rigor::Reflection.singleton_method_definition(class_name, name, scope: scope)
                else
                  Rigor::Reflection.instance_method_definition(class_name, name, scope: scope)
                end
          !rbs.nil? || scope.discovered_method?(class_name, name, side)
        end

        def answer(name, scope, sites)
          answers = sites.answers
          return answers[name] if answers.key?(name)

          answers[name] = project_may_rebind?(name, scope, sites)
        end

        # The method the block reaches: the call's own name, the literal name a `send` family call dispatches to, or
        # the method a Method object names. nil when a `send` names its method with anything but a literal, or with a
        # String that is no valid name, and for a `call` on anything but a literal `method(:name)`.
        def callee_name(call)
          return method_object_name(call.receiver) if METHOD_OBJECT_CALLS.include?(call.name)

          send_target(call)
        end

        def method_object_name(receiver)
          receiver = receiver.receiver while receiver.is_a?(Prism::CallNode) && METHOD_WRAPPERS.include?(receiver.name)
          return nil unless receiver.is_a?(Prism::CallNode) && METHOD_READERS.include?(receiver.name)

          literal_name(receiver.arguments&.arguments&.first)
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
