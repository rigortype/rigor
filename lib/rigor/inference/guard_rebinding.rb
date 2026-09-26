# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "../type"
require_relative "external_ancestor_resolution"
require_relative "fresh_frame_blocks"
require_relative "project_method_ownership"
require_relative "stored_block_call"

module Rigor
  module Inference
    # Issue #1429 — where a guard's narrowing of a global or constant stops holding. A guard narrows `$stdout` or
    # `STDOUT` on its edge ({Narrowing}), but any Ruby code that runs between the guard and a read may rebind the
    # global (`$stdout = StringIO.new`) or the constant (`const_set`), and the analysis cannot see that code. So the
    # statement evaluator restores each narrowed name to the union of its pre-guard binding and its narrowed one
    # ({Scope#forget_guard_narrowings}) wherever code this module counts may run:
    #
    # - a call that may run project, gem or unresolved code ({.call_runs_foreign_code?}): a method the project
    #   defines on the receiver's class or its ancestry, one whose signature is owned outside Ruby core and the
    #   standard library, a core method on a project or gem receiver (`Enumerable#map` runs the class's `each`),
    #   an unresolved callee (a `Dynamic` receiver, a name no signature declares), a call that runs code by name
    #   (`send`, `instance_eval`, `eval`, `require`, `load`), a call on a code object (`Proc`, `Method`,
    #   `Enumerator`, `Fiber`, `Thread`, a delegator), and a block-pass argument (`&blk`);
    # - a literal block whose body may do either, or writes a global or constant itself;
    # - `yield` and `super`, which run code the method does not show.
    #
    # A core or standard-library method on a core or standard-library receiver keeps the narrowing (`$sep.strip`,
    # `$stdout.flush`, `File.read(path)`), and so does a method `Kernel`, `Object` or `BasicObject` owns on any
    # receiver (`puts`, `format`, `obj.frozen?`), so `if $sep; $sep.strip; $sep.length; end` keeps `$sep` non-nil.
    #
    # The accepted gap is implicit conversion: a core method that calls back into a project method the program
    # does not spell (`puts obj` runs `obj.to_s`, `hash[obj]` runs `obj.hash`, `a.sort` runs `<=>`) is read as the
    # core method alone.
    module GuardRebinding
      # Calls that run code chosen by name or by a String.
      CODE_RUNNING_NAMES = Set[
        :send, :__send__, :public_send, :eval, :require, :require_relative, :load,
        # These rebind a constant on any receiver (`Object.const_set(:SEP, nil)`).
        :const_set, :remove_const
      ].freeze
      # These run their literal block, which the scan reads as any block, or a String of code, which it cannot read.
      BLOCK_OR_CODE_NAMES = Set[
        :instance_eval, :instance_exec, :class_eval, :class_exec, :module_eval, :module_exec
      ].freeze
      # Methods `Kernel`, `Object` or `BasicObject` own that call another method of the receiver, which a project class
      # may define: `r != 1` runs `r == 1`.
      UNIVERSAL_DELEGATES = { :!= => :==, :!~ => :=~, :=== => :==, :respond_to? => :respond_to_missing? }.freeze
      # Receivers whose methods run code the receiver holds: a block, a method, a generator or a delegate.
      CODE_OBJECT_CLASSES = Set[
        "Proc", "Method", "UnboundMethod", "Binding", "Enumerator", "Enumerator::Lazy", "Enumerator::Chain",
        "Enumerator::Yielder", "Fiber", "Thread", "Delegator", "SimpleDelegator"
      ].freeze
      # The owners whose methods a project object answers the same way any object does.
      UNIVERSAL_OWNERS = Set["Kernel", "Object", "BasicObject"].freeze
      # The nodes that write a global or a constant.
      WRITE_NODES = [
        Prism::GlobalVariableWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
        Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableTargetNode,
        Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
        Prism::ConstantOperatorWriteNode, Prism::ConstantTargetNode, Prism::ConstantPathWriteNode,
        Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode,
        Prism::ConstantPathTargetNode
      ].freeze
      # Code that runs code the method does not show.
      FOREIGN_NODES = [Prism::YieldNode, Prism::SuperNode, Prism::ForwardingSuperNode].freeze
      REBINDING_NODES = (WRITE_NODES + FOREIGN_NODES).to_set.freeze
      # Nodes that call methods the syntax does not spell as a `CallNode`: an operator write calls its operator (`r +=
      # 1` calls `r.+`), an attribute or index compound write calls the reader and the writer (`r.val ||= 1`, `r[0] +=
      # 1`), and a `for` loop calls `each` on its collection.
      IMPLICIT_CALL_NODES = Set[
        Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode,
        Prism::ClassVariableOperatorWriteNode, Prism::CallOperatorWriteNode, Prism::CallOrWriteNode,
        Prism::CallAndWriteNode, Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
        Prism::ForNode
      ].freeze
      VARIABLE_OPERATOR_WRITES = {
        Prism::LocalVariableOperatorWriteNode => :local, Prism::InstanceVariableOperatorWriteNode => :ivar,
        Prism::ClassVariableOperatorWriteNode => :cvar
      }.freeze
      private_constant :CODE_RUNNING_NAMES, :BLOCK_OR_CODE_NAMES, :UNIVERSAL_DELEGATES, :CODE_OBJECT_CLASSES,
                       :UNIVERSAL_OWNERS, :WRITE_NODES, :FOREIGN_NODES,
                       :REBINDING_NODES, :IMPLICIT_CALL_NODES, :VARIABLE_OPERATOR_WRITES

      module_function

      # True when `call_node`, a statement's own call, may rebind a global or constant once its operands ran: its
      # method may run foreign code, or its literal block may.
      def call_may_rebind?(call_node, scope)
        return true unless call_node.is_a?(Prism::CallNode)
        return true if call_runs_foreign_code?(call_node, scope)

        block = call_node.block
        block.is_a?(Prism::BlockNode) && may_rebind?(block, scope)
      end

      # True when the receiver chain or the arguments of `call_node` may rebind one; Ruby runs them before the call.
      def operands_may_rebind?(call_node, scope)
        may_rebind?(call_node.receiver, scope) || may_rebind?(call_node.arguments, scope) ||
          (call_node.block.is_a?(Prism::BlockArgumentNode) && may_rebind?(call_node.block, scope))
      end

      # True when running `node` may rebind one: it writes a global or constant, yields, calls `super`, or holds a
      # call, spelled or implicit ({.implicit_call_may_rebind?}), whose method may run foreign code. A `def` and a
      # lambda literal run nothing where they are written. Each node is visited once: a call's literal block is
      # reached as one of its children, so a nested block chain costs its size, not its depth's power.
      def may_rebind?(node, scope)
        return false unless node.is_a?(Prism::Node)
        return true if REBINDING_NODES.include?(node.class)
        return false if node.is_a?(Prism::DefNode) || node.is_a?(Prism::LambdaNode)
        return true if node.is_a?(Prism::CallNode) && call_runs_foreign_code?(node, scope)
        return true if IMPLICIT_CALL_NODES.include?(node.class) && implicit_call_may_rebind?(node, scope)

        found = false
        node.rigor_each_child { |child| found ||= may_rebind?(child, scope) }
        found
      end

      # True when `node` is a compound write or `for` loop that calls a method its syntax does not spell.
      def implicit_call_node?(node)
        IMPLICIT_CALL_NODES.include?(node.class)
      end

      # True when the method a compound write or a `for` loop calls without spelling it may run foreign code
      # ({IMPLICIT_CALL_NODES}). The operator of an attribute or index operator write runs on the value the reader
      # returns, typed through the dispatcher; one it cannot type counts.
      def implicit_call_may_rebind?(node, scope)
        kind = VARIABLE_OPERATOR_WRITES[node.class]
        return type_method_foreign?(variable_type(kind, node.name, scope), node.binary_operator, scope) if kind
        return type_method_foreign?(scope.type_of(node.collection), :each, scope) if node.is_a?(Prism::ForNode)

        compound_write_foreign?(node, scope)
      rescue StandardError
        true
      end

      def compound_write_foreign?(node, scope)
        receiver_type = compound_receiver_type(node, scope)
        reader, writer = compound_accessors(node)
        return true if [reader, writer].any? { |name| type_method_foreign?(receiver_type, name, scope) }
        return false unless node.respond_to?(:binary_operator)

        read = compound_read_type(node, receiver_type, reader, scope)
        read.nil? || type_method_foreign?(read, node.binary_operator, scope)
      end

      def compound_receiver_type(node, scope)
        return scope.type_of(node.receiver) if node.receiver

        scope.self_type || Type::Combinator.nominal_of("Object")
      end

      def compound_accessors(node)
        return %i[[] []=] if node.respond_to?(:arguments) && !node.respond_to?(:read_name)

        [node.read_name, node.write_name]
      end

      def compound_read_type(node, receiver_type, reader, scope)
        arguments = node.respond_to?(:arguments) && node.arguments ? node.arguments.arguments : []
        MethodDispatcher.dispatch(receiver_type: receiver_type, method_name: reader,
                                  arg_types: arguments.map { |argument| scope.type_of(argument) },
                                  environment: scope.environment, scope: scope)
      end

      def variable_type(kind, name, scope)
        case kind
        when :local then scope.local(name)
        when :ivar then scope.ivar(name)
        else scope.cvar(name)
        end || Type::Combinator.untyped
      end

      # True when `method_name` on a value of `type` may run foreign code ({.foreign_target?}).
      def type_method_foreign?(type, method_name, scope)
        targets = ProjectMethodOwnership.targets(type)
        return true if targets.nil? || targets.empty?

        targets.any? { |class_name, kind| foreign_target?(class_name, method_name, kind, scope) }
      end

      # The scope the body of `block_node` (a block or a lambda literal) enters with: `scope` with its guard
      # narrowings restored where the body may run after code that rebinds them. A lambda, a block the call keeps
      # to run later (`proc`, `define_method`), the root block of a thread or fiber, the block of a call that
      # itself may run foreign code (`with_retry { $g.length }` runs after the helper's body), and a body that may
      # rebind one itself (a later run reads what an earlier one wrote). A block with no owning call is left alone.
      def block_entry(scope, block_node, call_node)
        return scope unless scope.guard_narrowed?
        return scope.forget_guard_narrowings if block_node.is_a?(Prism::LambdaNode)
        return scope unless call_node.is_a?(Prism::CallNode)

        if StoredBlockCall.stores_block?(call_node) || FreshFrameBlocks.fresh_entry?(call_node, scope) ||
           call_runs_foreign_code?(call_node, scope) || may_rebind?(block_node, scope)
          return scope.forget_guard_narrowings
        end

        scope
      end

      # True when the method `call_node` calls may run code other than Ruby core and the standard library (see the
      # module comment). Its operands and literal block are not read here.
      def call_runs_foreign_code?(call_node, scope)
        return true if call_node.block.is_a?(Prism::BlockArgumentNode)
        return true if CODE_RUNNING_NAMES.include?(call_node.name)
        return true if BLOCK_OR_CODE_NAMES.include?(call_node.name) &&
                       !(call_node.block.is_a?(Prism::BlockNode) && call_node.arguments.nil?)

        targets = receiver_targets(call_node, scope)
        return true if targets.nil? || targets.empty?

        targets.any? { |class_name, kind| foreign_target?(class_name, call_node.name, kind, scope) }
      rescue StandardError
        true
      end

      # The `[class_name, kind]` pairs the call dispatches on ({ProjectMethodOwnership.targets}); an implicit or
      # `self.` receiver reads the scope's `self`, and the top level's `main` is an `Object`.
      def receiver_targets(call_node, scope)
        receiver = call_node.receiver
        if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          self_type = scope.self_type
          return [["Object", :instance]] if self_type.nil?

          return ProjectMethodOwnership.targets(self_type)
        end

        ProjectMethodOwnership.targets(Narrowing.guard_facet_type(receiver, scope.type_of(receiver), scope))
      end

      def foreign_target?(class_name, method_name, kind, scope)
        return true if CODE_OBJECT_CLASSES.include?(class_name)
        return true if ProjectMethodOwnership.defines?(class_name, method_name, kind, scope)

        owner = method_owner(class_name, method_name, kind, scope)
        return true if owner.nil?
        return universal_delegate_foreign?(class_name, method_name, kind, scope) if UNIVERSAL_OWNERS.include?(owner)

        loader = scope.environment.rbs_loader
        return true if loader.nil?

        !(loader.core_or_stdlib_class?(owner) && loader.core_or_stdlib_class?(class_name))
      end

      # A universal method is foreign only when it calls another method of the receiver the project defines
      # ({UNIVERSAL_DELEGATES}).
      def universal_delegate_foreign?(class_name, method_name, kind, scope)
        delegate = UNIVERSAL_DELEGATES[method_name]
        !delegate.nil? && ProjectMethodOwnership.defines?(class_name, delegate, kind, scope)
      end

      # The class or module whose signature answers `method_name` on `class_name`: its own RBS, an RBS ancestor of a
      # project class ({ExternalAncestorResolution.resolve}), or `Object`'s for an instance method nothing earlier
      # declares (a project class with no signature calling `puts`). nil when none does.
      def method_owner(class_name, method_name, kind, scope)
        definition = ExternalAncestorResolution.method_definition(class_name, method_name, kind, scope: scope)
        if definition.nil? && kind == :instance
          definition = ExternalAncestorResolution.resolve(class_name, method_name, :instance, scope: scope)&.first
          definition ||= ExternalAncestorResolution.method_definition("Object", method_name, :instance, scope: scope)
        end
        owner = definition.respond_to?(:defined_in) ? definition.defined_in : nil
        owner&.to_s&.delete_prefix("::")
      end
      private_class_method :receiver_targets, :foreign_target?, :universal_delegate_foreign?, :method_owner,
                           :compound_write_foreign?,
                           :compound_receiver_type, :compound_accessors, :compound_read_type, :variable_type,
                           :type_method_foreign?
    end
  end
end
