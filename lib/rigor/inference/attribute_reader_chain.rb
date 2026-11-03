# frozen_string_literal: true

require "rbs"

require "prism"

require_relative "../reflection"
require_relative "../run_scoped_slots"
require_relative "../source/node_children"
require_relative "../type"

module Rigor
  module Inference
    # Issue #2685 — whether a no-argument call `x.r` reads a stored attribute, so a truthiness or `nil?` guard
    # on it may carry to the next `x.r` read ({Narrowing}'s single-hop chain narrowing).
    #
    # It does when, for every non-nil member of the receiver's type, the RBS of that class or one of its
    # RBS ancestors declares `r` with `attr_reader` or `attr_accessor`, and the project cannot answer `r`
    # some other way ({.project_may_redefine?}). What the rule relies on is narrower than "an attribute
    # returns its instance variable", which some RBS attributes do not do (a memoising reader, a reader
    # computed from other state): it is that the reader's nil-ness does not change between two reads with no
    # call on the receiver between them. A method declared with `def` carries no such promise (`queue.pop`,
    # `io.gets`) and stays un-narrowed, as does a receiver Rigor cannot name (`Dynamic`, an interface, a
    # project class with no RBS).
    #
    # A `nil` member is skipped: on it the plain call raises and the `&.` call returns `nil` without calling
    # `r`, so neither reaches a guarded re-read with a value the guard did not see.
    #
    # The rule reads only RBS, so an `attr_reader` written in project Ruby without a signature does not
    # qualify; that is a follow-up, not part of this rule.
    module AttributeReaderChain
      ATTRIBUTE_MEMBERS = [::RBS::AST::Members::AttrReader, ::RBS::AST::Members::AttrAccessor].freeze
      TOP_LEVEL_DEF_KEY = "<toplevel>"
      private_constant :ATTRIBUTE_MEMBERS, :TOP_LEVEL_DEF_KEY

      CENSUS_KEY = RunScopedSlots.register(:__rigor_attribute_reader_chain_census__)
      private_constant :CENSUS_KEY

      module_function

      # @param call_node — a no-argument, block-free `Prism::CallNode` rooted at a local or instance variable
      #   ({Narrowing}'s stable chain address has already been checked).
      def attribute_read?(call_node, scope)
        attribute_on?(scope.type_of(call_node.receiver), call_node.name, scope)
      end

      # Whether `method_name` is a stored attribute on every non-nil member of `receiver_type`.
      def attribute_on?(receiver_type, method_name, scope)
        return false if receiver_type.nil?

        members = receiver_type.is_a?(Type::Union) ? receiver_type.members : [receiver_type]
        owners = members.reject { |member| member.is_a?(Type::Constant) && member.value.nil? }
        return false if owners.empty?

        owners.all? { |member| attribute_owner?(member, method_name, scope) }
      end

      def attribute_owner?(member, method_name, scope)
        return false unless member.is_a?(Type::Nominal)

        declared_attribute?(member.class_name, method_name, scope) &&
          !project_may_redefine?(member.class_name, method_name, scope)
      end

      def declared_attribute?(class_name, method_name, scope)
        definition = Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
        return false if definition.nil? || definition.defs.empty?

        definition.defs.all? { |type_def| ATTRIBUTE_MEMBERS.any? { |klass| type_def.member.is_a?(klass) } }
      rescue ::RBS::BaseError
        false
      end

      # Whether project code may answer `method_name` on a `class_name` receiver instead of the RBS attribute.
      # Three readings, each conservative:
      #
      # - **By name, anywhere in the project** ({.redefined_name?}): a non-`def` definition of the name on any
      #   class or module (`define_method`, `attr_*`, an alias with no `def` behind it, which the discovery
      #   table records), and a top-level `def` of it.
      # - **By class**: a project class or module that rewrites its method table beyond the names it spells (a
      #   computed `define_method`, `send(:define_method, …)`, `define_singleton_method` in its body, a refined
      #   class) and is the receiver's class, an ancestor of it, or a descendant of it. A refinement takes effect
      #   only in a file with `using`, and one of a class the walk cannot name leaves such a file's calls
      #   `Dynamic` already, so a refinement is read by the class it refines.
      # - **A `def`** on the class, an ancestor, or a descendant
      #   ({ExpressionTyper#instance_method_redefined_in_project?}).
      def project_may_redefine?(class_name, method_name, scope)
        redefined_name?(method_name, scope) || rewritten_in_reach?(class_name, scope) ||
          ExpressionTyper.new(scope: scope).instance_method_redefined_in_project?(class_name, method_name)
      end

      def redefined_name?(method_name, scope)
        Analysis::DependencyRecorder.read_name(:defines, method_name) if Analysis::DependencyRecorder.active?
        census(scope)[:names].include?(method_name.to_sym)
      end

      def rewritten_in_reach?(class_name, scope)
        memo = census(scope)[:rewritten_reach]
        key = class_name.to_s
        return memo[key] if memo.key?(key)

        memo[key] = census(scope)[:rewritten].any? do |owner|
          owner == key || descends_from?(owner, key, scope) || descends_from?(key, owner, scope)
        end
      end

      # Whether `candidate`'s instance chain reaches `owner`. `owner` is often an RBS class, which a project
      # class's {Scope::ResolutionChain} holds only as an external entry; such an entry relates when one of its
      # candidate names is `owner` or an RBS subclass of it.
      def descends_from?(candidate, owner, scope)
        environment = scope.environment
        chain = Scope::ResolutionChain.for(scope, candidate.to_s, :instance, :methods)
        found = chain.search(scope) do |entry|
          next entry.name == owner unless entry.external?

          entry.candidates.any? { |name| name == owner || environment.class_ordering(name, owner) == :subclass }
        end
        !found.nil?
      end

      # Calls that run a closure the receiver holds: `.call` and `.()` on anything, and `[]` / `yield` / `===` on a
      # value typed `Proc` or `Method`.
      PROC_CALL_NAMES = %i[[] yield ===].freeze
      CALLABLE_CLASSES = %w[Proc Method].freeze
      private_constant :PROC_CALL_NAMES, :CALLABLE_CLASSES

      # `scope` past `call_node`, without the attribute-chain facts code the call may run could falsify, beyond the
      # existing rule that any call on the root drops every fact rooted there ({IndexedNarrowing}):
      #
      # - every fact, after a call that runs a closure (`clear.call`, `clear.()`, `blk[]` on a `Proc`);
      # - a fact rooted at a variable, after a call whose block or lambda argument mentions that variable
      #   (`items.each { x.r = nil }`, `1.tap { … }`), since the closure may write through it;
      # - a fact rooted at an instance variable, after an implicit-self or `self.` call, or a call whose closure
      #   makes one (`reset!`, `items.each { reset! }`), since that method may write the ivar or its attribute.
      #
      # Only attribute-chain facts are dropped: a fact this rule's gate does not admit is an `is_a?` guard's, whose
      # invalidation stays as it was.
      def after_call(call_node, scope)
        facts = scope.method_chain_narrowings
        return scope if facts.empty?

        closures = closures_in(call_node)
        runs_closure = runs_closure?(call_node, scope)
        self_call = self_call?(call_node) || closures.any? { |closure| self_call_inside?(closure) }
        facts.each_key.reduce(scope) do |acc, key|
          next acc unless runs_closure || mentioned?(key, closures) || (self_call && key.receiver_kind == :ivar)
          next acc unless attribute_fact?(key, scope)

          acc.without_method_chain_narrowing(key.receiver_kind, key.receiver_name, key.method_name)
        end
      end

      # Whether `key` may be an attribute fact. A root whose binding the scope does not hold (an instance variable
      # typed from its class seed) answers yes, the dropping direction.
      def attribute_fact?(key, scope)
        root = key.receiver_kind == :local ? scope.local(key.receiver_name) : scope.ivar(key.receiver_name)
        root.nil? || attribute_on?(root, key.method_name, scope)
      end

      def runs_closure?(call_node, scope)
        return false if call_node.receiver.nil?
        return true if call_node.name == :call
        return false unless PROC_CALL_NAMES.include?(call_node.name)

        receiver = scope.type_of(call_node.receiver)
        members = receiver.is_a?(Type::Union) ? receiver.members : [receiver]
        members.any? { |member| member.is_a?(Type::Nominal) && CALLABLE_CLASSES.include?(member.class_name) }
      end

      def self_call?(call_node)
        call_node.receiver.nil? || call_node.receiver.is_a?(Prism::SelfNode)
      end

      # The blocks and lambdas the call carries: its block, and any lambda among its receiver and arguments.
      def closures_in(call_node)
        closures = []
        closures << call_node.block if call_node.block.is_a?(Prism::BlockNode)
        [call_node.receiver, call_node.arguments].each { |part| collect_lambdas(part, closures) }
        closures
      end

      def collect_lambdas(node, closures)
        return unless node.is_a?(Prism::Node)
        return closures << node if node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::BlockNode)

        node.rigor_each_child { |child| collect_lambdas(child, closures) }
      end

      LOCAL_NODES = [Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode, Prism::LocalVariableTargetNode,
                     Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
                     Prism::LocalVariableAndWriteNode].freeze
      IVAR_NODES = [Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode,
                    Prism::InstanceVariableTargetNode, Prism::InstanceVariableOperatorWriteNode,
                    Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode].freeze
      private_constant :LOCAL_NODES, :IVAR_NODES

      def mentioned?(key, closures)
        kinds = key.receiver_kind == :local ? LOCAL_NODES : IVAR_NODES
        closures.any? { |closure| mentions?(closure, kinds, key.receiver_name) }
      end

      def mentions?(node, kinds, name)
        return false unless node.is_a?(Prism::Node)
        return true if kinds.any? { |klass| node.is_a?(klass) } && node.name == name

        node.rigor_each_child { |child| return true if mentions?(child, kinds, name) }
        false
      end

      def self_call_inside?(node)
        return false unless node.is_a?(Prism::Node)
        return true if node.is_a?(Prism::CallNode) && self_call?(node)

        node.rigor_each_child { |child| return true if self_call_inside?(child) }
        false
      end

      # The name census and the rewritten-surface owners, built once per discovery index.
      def census(scope)
        discovery = scope.discovery
        slot = Thread.current[CENSUS_KEY]
        return slot[1] if slot && slot[0].equal?(discovery)

        built = { names: redefined_names(discovery), rewritten: rewritten_owners(discovery), rewritten_reach: {} }
        Thread.current[CENSUS_KEY] = [discovery, built]
        built
      end

      def redefined_names(discovery)
        names = Set.new
        def_nodes = discovery.discovered_def_nodes
        discovery.discovered_methods.each do |owner, methods|
          defs = def_nodes[owner]
          methods.each { |name, kind| names << name.to_sym unless kind == :singleton || defs&.key?(name) }
        end
        def_nodes[TOP_LEVEL_DEF_KEY]&.each_key { |name| names << name.to_sym }
        names.freeze
      end

      def rewritten_owners(discovery)
        discovery.discovered_parameter_envelopes.filter_map do |owner, bucket|
          owner if Scope::DiscoveryIndex.rewritten_surface?(bucket)
        end.freeze
      end
    end
  end
end
