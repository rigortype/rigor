# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"
require_relative "../type"
require_relative "guard_rebinding"
require_relative "project_method_ownership"
require_relative "refined_dispatch/own_method"

module Rigor
  module Inference
    # Issue #1596 — the instance variables an implicit-self or `self.` statement call may write, when the analysis
    # can prove that set. The intervening-call reset (`StatementEvaluator#invalidate_ivars_for_intervening_call`)
    # and the class-guard restore ({GuardRebinding}) both assume such a call may write any instance variable and
    # run any code; with a proven set they widen only the instance variables in it, so `return unless
    # @io.is_a?(StringIO); log("dumping"); @io.string` keeps `@io` a `StringIO` when `log` writes no instance
    # variable.
    #
    # {.of} answers a frozen `Set` of names, or nil when it cannot prove one. It proves one only for an instance
    # method's `self` (a project class, not a module, whose instance chain the resolution chain settles) and a call
    # with no block argument (`&blk`, `...`), and only when every method the call can reach is proven:
    #
    # - A method the project defines on the class's chain must resolve to one `def` (not `define_method`, an
    #   `attr_*` writer or an alias), found ahead of every external ancestor, with every project subclass resolving
    #   the name to the same definer, and no `refine` block defining the name. Its parameters' default values and
    #   its body are read. A recursive or mutually recursive call adds nothing the first read did not.
    # - Any other method on `self` must be one {GuardRebinding} counts as running no foreign code (`warn`, `puts`,
    #   `format`), and not a code-running name (`send`, `instance_variable_set`, `instance_eval`, …).
    # - A call on another receiver counts only on a literal, a global, a constant naming a core or standard-library
    #   class, or an instance variable read as its class-ivar seed, and only when {GuardRebinding} counts its method
    #   as running no foreign code there. A local, a parameter or a call result is a receiver the read cannot type.
    #
    # Read code that writes an instance variable adds its name (an `instance_variable_set` call is a code-running
    # name, so it proves nothing). Code that writes a global or a constant, yields, calls `super`, defines a method
    # or opens a singleton class, an operator write on a local, and a `for` loop prove nothing. A literal block at
    # the call site or in a read body is read with the code around it. The accepted gap is {GuardRebinding}'s:
    # an implicit conversion a core method runs (`warn obj` runs `obj.to_s`) is read as the core method alone, and
    # so is a singleton method an `extend` or `def obj.m` gives one object at run time.
    module SelfCallIvarWrites
      # The most `def` bodies one proof reads before it gives up.
      DEF_BUDGET = 32
      # Code the proof does not read past: it rebinds a global or constant, runs code the body does not show, or
      # changes which method a later call dispatches to.
      UNPROVABLE_NODES = Set[
        Prism::GlobalVariableWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableAndWriteNode,
        Prism::GlobalVariableOperatorWriteNode, Prism::GlobalVariableTargetNode,
        Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode,
        Prism::ConstantOperatorWriteNode, Prism::ConstantTargetNode, Prism::ConstantPathWriteNode,
        Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode,
        Prism::ConstantPathTargetNode,
        Prism::YieldNode, Prism::SuperNode, Prism::ForwardingSuperNode, Prism::ForwardingArgumentsNode,
        Prism::BlockArgumentNode, Prism::DefNode, Prism::SingletonClassNode, Prism::ForNode,
        Prism::LocalVariableOperatorWriteNode, Prism::ClassVariableOperatorWriteNode, Prism::CallOperatorWriteNode,
        Prism::CallOrWriteNode, Prism::CallAndWriteNode, Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode,
        Prism::IndexAndWriteNode
      ].freeze
      # Literal receivers, by the core class their value is an instance of.
      LITERAL_CLASSES = {
        Prism::StringNode => "String", Prism::InterpolatedStringNode => "String", Prism::XStringNode => "String",
        Prism::SymbolNode => "Symbol", Prism::InterpolatedSymbolNode => "Symbol", Prism::IntegerNode => "Integer",
        Prism::FloatNode => "Float", Prism::ArrayNode => "Array", Prism::HashNode => "Hash",
        Prism::RangeNode => "Range", Prism::RegularExpressionNode => "Regexp",
        Prism::InterpolatedRegularExpressionNode => "Regexp", Prism::NilNode => "NilClass",
        Prism::TrueNode => "TrueClass", Prism::FalseNode => "FalseClass"
      }.freeze
      # Methods `Kernel` or `Object` own that change which method a later call on `self` dispatches to, run an
      # `extended` hook, or hand out `self`'s methods or binding as objects.
      DISPATCH_CHANGING_NAMES = Set[
        :extend, :define_singleton_method, :singleton_class, :method, :public_method, :singleton_method, :binding
      ].freeze
      private_constant :UNPROVABLE_NODES, :LITERAL_CLASSES, :DISPATCH_CHANGING_NAMES

      # Raised inside a proof to abandon it.
      class Unprovable < StandardError
      end
      private_constant :Unprovable

      module_function

      # The names of the instance variables `call_node`, an implicit-self or `self.` call, may write, as a frozen
      # `Set`, or nil when the analysis cannot prove the set. `scope` is the scope the call's operands were typed in.
      def of(call_node, scope)
        return nil unless call_node.is_a?(Prism::CallNode)
        return nil unless call_node.receiver.nil? || call_node.receiver.is_a?(Prism::SelfNode)

        self_type = scope.self_type
        return nil unless self_type.is_a?(Type::Nominal)

        proof = Proof.new(self_type, scope)
        proof.self_call(call_node)
        proof.read(call_node.block)
        proof.written.freeze
      rescue StandardError # an `Unprovable`, or a lookup that raised: either proves nothing
        nil
      end

      # One proof's state: the instance variables read code writes, and the `def` bodies already read.
      class Proof
        attr_reader :written

        def initialize(self_type, scope)
          @self_type = self_type
          @class_name = self_type.class_name
          @scope = scope
          @written = Set.new
          @visited = {}.compare_by_identity
        end

        # Reads the method an implicit-self or `self.` call to `call_node`'s name runs.
        def self_call(call_node)
          name = call_node.name
          unprovable! if GuardRebinding.code_running_name?(name) || DISPATCH_CHANGING_NAMES.include?(name)

          if ProjectMethodOwnership.defines?(@class_name, name, :instance, @scope)
            read_def(proven_def(name))
          elsif GuardRebinding.type_method_foreign?(@self_type, name, @scope)
            unprovable!
          end
        end

        # Reads `node`, adding each instance variable it writes.
        def read(node)
          return unless node.is_a?(Prism::Node)

          unprovable! if UNPROVABLE_NODES.include?(node.class)
          written = ivar_write_name(node)
          @written << written if written
          if node.is_a?(Prism::InstanceVariableOperatorWriteNode) && GuardRebinding.type_method_foreign?(
            ivar_seed(node.name), node.binary_operator, @scope
          )
            unprovable!
          end
          read_call(node) if node.is_a?(Prism::CallNode)
          node.rigor_each_child { |child| read(child) }
        end

        private

        def ivar_write_name(node)
          case node
          when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
               Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableTargetNode
            node.name
          end
        end

        def read_call(node)
          receiver = node.receiver
          return self_call(node) if receiver.nil? || receiver.is_a?(Prism::SelfNode)

          unprovable! if GuardRebinding.code_running_name?(node.name)
          type = receiver_type(receiver)
          unprovable! if type.nil? || GuardRebinding.type_method_foreign?(type, node.name, @scope)
        end

        def read_def(def_node)
          return if @visited.key?(def_node)

          @visited[def_node] = true
          unprovable! if @visited.size > DEF_BUDGET
          read(def_node.parameters)
          read(def_node.body)
        end

        # The `def` the name resolves to on the class and on every project subclass, or unprovable.
        def proven_def(name)
          unprovable! if RefinedDispatch::OwnMethod.module_name?(@scope, @class_name)
          unprovable! if @scope.discovered_refinements.any? { |_refined, methods| methods.key?(name) }

          owner = definer_ahead(@class_name, name, nil)
          unprovable! if owner.nil?
          def_node = @scope.user_def_for(owner, name)
          unprovable! unless def_node.is_a?(Prism::DefNode) && def_node.receiver.nil?

          # A subclass whose superclass the tables do not know is enumerated too, and its chain ends short of the
          # owner; one that reaches no definer of its own leaves the call to its superclass.
          RefinedDispatch::OwnMethod.each_subclass(@scope, @class_name) do |subclass|
            unprovable! unless [owner, nil].include?(definer_ahead(subclass, name, owner))
          end
          def_node
        end

        # The first project class or module on `class_name`'s settled instance chain that defines `name`, stopping
        # at `owner`; nil when the chain ends without one. An external ancestor reached first is unprovable: its
        # signature, or a gem without one, may define the name.
        def definer_ahead(class_name, name, owner)
          chain = Scope::ResolutionChain.for(@scope, class_name.to_s, :instance, :methods)
          unprovable! if chain.truncated? || chain.wildcard_mixin? || chain.unsettled? || chain.forks.positive?

          chain.search(@scope) do |entry|
            unprovable! if entry.external?

            entry.name if entry.name == owner || defines_here?(entry.name, name)
          end
        end

        # A `def`, `define_method`, `attr_*` or alias of `name` in `class_name`'s own body: the discovery table holds
        # the last three project-wide, and the `def` table the first.
        def defines_here?(class_name, name)
          @scope.discovered_method?(class_name, name, :instance) || !@scope.def_node_slot(class_name, name).nil?
        end

        def receiver_type(node)
          literal = LITERAL_CLASSES[node.class]
          return Type::Combinator.nominal_of(literal) if literal

          case node
          when Prism::GlobalVariableReadNode then @scope.type_of(node)
          when Prism::InstanceVariableReadNode then ivar_seed(node.name)
          when Prism::ConstantReadNode, Prism::ConstantPathNode then core_constant_type(node)
          end
        end

        def ivar_seed(name)
          @scope.class_ivars_for(@class_name)[name] || unprovable!
        end

        # A constant receiver read in the caller's scope, which the callee's lexical scope may resolve otherwise: only
        # a core or standard-library class object or instance, under a name no project class or constant ends with.
        def core_constant_type(node)
          type = @scope.type_of(node)
          return nil unless type.is_a?(Type::Singleton) || type.is_a?(Type::Nominal)

          loader = @scope.environment.rbs_loader
          return nil if loader.nil? || !loader.core_or_stdlib_class?(type.class_name)

          segment = node.name.to_s
          project = [@scope.discovered_classes, @scope.in_source_constants]
          return nil if project.any? { |table| table.each_key.any? { |name| name.to_s.split("::").last == segment } }

          type
        end

        def unprovable!
          raise Unprovable
        end
      end
    end
  end
end
