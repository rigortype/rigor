# frozen_string_literal: true

require "prism"

require_relative "../analysis/dependency_recorder"
require_relative "../source/node_children"
require_relative "../source/parameter_envelope"
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
      # The methods `Kernel` or `Object` own that a read accepts on `self` when the project does not define them. Any
      # other (`display`, `inspect`, `==`, `hash`, `extend`, `method`, `binding`, `instance_variables`) proves nothing.
      # These may still convert a value they are given, which runs that value's methods: {PROTOCOL_NAMES} answers for
      # a value that is `self`.
      SELF_SAFE_NAMES = Set[
        :warn, :puts, :print, :p, :pp, :format, :sprintf, :printf, :raise, :fail, :loop, :catch, :throw, :rand,
        :sleep, :Integer, :Float, :String, :Array, :Hash, :Rational, :Complex, :block_given?, :frozen?, :nil?,
        :is_a?, :kind_of?, :instance_of?, :object_id, :class, :__method__, :caller, :abort, :exit
      ].freeze
      # Issue #1596 — the methods core code calls on a value without the program spelling them: conversions,
      # comparisons, hashing, iteration, `respond_to?` and its hook, `exception` for `raise`, `divmod` for `sleep`.
      # A value aliasing `self` (`@me = self`, `me = self`, a constant holding the instance) handed to a core
      # method runs `self`'s own definition of one of these, which the read never sees, so a class defining any
      # proves nothing.
      PROTOCOL_NAMES = Set[
        :to_s, :inspect, :hash, :eql?, :==, :===, :<=>, :to_a, :to_ary, :to_str, :to_hash, :to_int, :to_i, :to_f,
        :to_r, :to_c, :to_proc, :to_path, :to_sym, :to_io, :coerce, :exception, :divmod, :each, :respond_to?,
        :respond_to_missing?, :method_missing, :initialize_copy, :marshal_dump, :pretty_print
      ].freeze
      private_constant :UNPROVABLE_NODES, :LITERAL_CLASSES, :SELF_SAFE_NAMES, :PROTOCOL_NAMES

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
        proof.no_self_value(call_node.arguments)
        proof.no_protocol_override
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
          unprovable! if GuardRebinding.code_running_name?(name) || refined?(name)

          if ProjectMethodOwnership.defines?(@class_name, name, :instance, @scope)
            read_def(proven_def(name))
          elsif !SELF_SAFE_NAMES.include?(name) || GuardRebinding.type_method_foreign?(@self_type, name, @scope)
            unprovable!
          end
        end

        # Issue #1596 — gives up when `self`'s class, a project subclass, or a project ancestor or module on either's
        # chain defines a {PROTOCOL_NAMES} method (a `def`, `define_method`, `attr_*` or alias), rewrites its methods
        # beyond the names it spells, or is refined on one; or when either chain holds an external ancestor, whose
        # own definitions the read cannot see. Issue #1979 — a class built on a core constructor call
        # (`class Fact < Data.define(:a)`) cannot be `self`'s class or a subclass of it, so the walk leaves it out.
        def no_protocol_override
          classes = [@class_name]
          RefinedDispatch::OwnMethod.each_subclass(@scope, @class_name, possible_only: true) { |subclass| classes << subclass }
          classes.each do |class_name|
            chain = Scope::ResolutionChain.for(@scope, class_name.to_s, :instance, :methods)
            unprovable! if chain.truncated? || chain.wildcard_mixin? || !settled?(chain)
            chain.search(@scope) do |entry|
              unprovable! if entry.external? || rewritten?(entry.name) || protocol_defined?(entry.name)
              nil
            end
          end
        end

        # Issue #1596 — `self` handed on as a value (an argument, an interpolation, a splat, a `when` value, a literal
        # element or key) lets the code it reaches run `self`'s methods by protocol (`to_s`, `hash`, `==`, `to_a`),
        # which the read does not follow, so it proves nothing. Reads `node` for one, without reading anything else.
        def no_self_value(node)
          return unless node.is_a?(Prism::Node)

          unprovable! if node.is_a?(Prism::SelfNode)
          node.rigor_each_child { |child| no_self_value(child) }
        end

        # Reads `node`, adding each instance variable it writes.
        def read(node)
          return unless node.is_a?(Prism::Node)

          unprovable! if UNPROVABLE_NODES.include?(node.class) || node.is_a?(Prism::SelfNode)
          written = ivar_write_name(node)
          @written << written if written
          if node.is_a?(Prism::InstanceVariableOperatorWriteNode) && GuardRebinding.type_method_foreign?(
            ivar_seed(node.name), node.binary_operator, @scope
          )
            unprovable!
          end
          read_call(node) if node.is_a?(Prism::CallNode)
          # `self.m` is the one place `self` may stand: a call on it, which {#read_call} read.
          receiver = call_receiver(node)
          node.rigor_each_child { |child| read(child) unless child.is_a?(Prism::SelfNode) && child.equal?(receiver) }
        end

        private

        # Whether a `refine` block anywhere in the project defines `name`, on any class: a `using` in effect where the
        # read code sits may route the call to it (`refine Kernel do def warn …`), whatever the receiver.
        #
        # Issue #2163 — the answer reads every file's refinements whole, and a refined class off the chain (`Kernel`,
        # `IO`, `String`) is no `mark:` the chain read files, so it records `refinement:<name>` and `refinement:*`
        # whichever way it answers, as `InEffectRefinements` consumers do: a file that starts or stops refining the
        # name re-checks the reader.
        def refined?(name)
          if Analysis::DependencyRecorder.active?
            Analysis::DependencyRecorder.read_name(:refinement, name)
            Analysis::DependencyRecorder.read_name(:refinement, Scope::DiscoveryIndex::REFINEMENT_WILDCARD)
          end
          @scope.discovered_refinements.any? { |_refined, methods| methods.key?(name) }
        end

        def call_receiver(node) = node.is_a?(Prism::CallNode) ? node.receiver : nil

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

          unprovable! if GuardRebinding.code_running_name?(node.name) || refined?(node.name)
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

          owner = definer_ahead(@class_name, name, nil)
          unprovable! if owner.nil?
          def_node = @scope.user_def_for(owner, name)
          unprovable! unless def_node.is_a?(Prism::DefNode) && def_node.receiver.nil?
          single_definition(owner, name)

          # A subclass whose superclass the tables do not know is enumerated too, and its chain ends short of the
          # owner; one that reaches no definer of its own leaves the call to its superclass.
          RefinedDispatch::OwnMethod.each_subclass(@scope, @class_name, possible_only: true) do |subclass|
            unprovable! unless [owner, nil].include?(definer_ahead(subclass, name, owner))
          end
          def_node
        end

        # Issue #1596 — the `def` the table holds must be the owner's only definition of `name`: the owner declared in
        # one file, with one `def` of the name there (a reopening or a `class_eval` body in the same file is a second
        # one), and no `define_method`, `attr_*` or alias of it, nor a rewrite no literal names (`T.define_method`,
        # `T.send(:define_method, …)`, `T.class_eval` with a computed name), nor a definition the walk could not prove
        # runs (a possible or contested one, as `DefinerResolution` reads them). `Scope#parameter_envelopes_of` files
        # the class edge to every declaring file and, issue #2137, the `mark:` edge for a file that only marks it.
        def single_definition(owner, name)
          bucket = @scope.parameter_envelopes_of(owner)
          unprovable! if possible_definition?(owner, name)
          unprovable! if bucket[[:instance, name]] == Source::ParameterEnvelope::OPAQUE
          unprovable! if (@scope.discovered_class_sources[owner]&.size || 0) > 1
          unprovable! if definition_count(owner, name) > 1
        end

        def possible_definition?(owner, name)
          discovery = @scope.discovery
          discovery.possible_method?(owner, name, :instance) ||
            discovery.contested?(:discovered_def_nodes, [owner, name]) ||
            discovery.contested?(:discovered_parameter_envelopes, [owner, [:instance, name]])
        end

        def definition_count(owner, name)
          count = 0
          @scope.discovered_deferred_ranges.each_value do |rows|
            count += rows.count { |row| row[2] == name && row[3] == :instance && row[4] == owner }
          end
          count
        end

        # Whether `chain`'s own order stands with no second world: no order mark and no fork. `ResolutionChain#settle`
        # answers `:chain` for an answer no world can match only then; a fork sends it to the retro world, which the
        # block answers otherwise, or to master's order.
        def settled?(chain)
          chain.settle(@scope, :chain_order) { :other_world } == :chain
        end

        def protocol_defined?(class_name)
          refined = @scope.discovered_refinements[class_name] || {}
          PROTOCOL_NAMES.any? { |name| defines_here?(class_name, name) || refined.key?(name) }
        end

        # Whether the project rewrites `class_name`'s method table beyond the names it spells, or refines it.
        #
        # Issue #2137 — read through `Scope#parameter_envelopes_of`, which files the `mark:` edge: a `refine` of the
        # class from a file whose declared classes do not change fires no class key, and adding or removing it must
        # re-check the reader.
        def rewritten?(class_name)
          Scope::DiscoveryIndex.rewritten_surface?(@scope.parameter_envelopes_of(class_name))
        end

        # The first project class or module on `class_name`'s settled instance chain that defines `name`, stopping
        # at `owner`; nil when the chain ends without one. An external ancestor reached first is unprovable: its
        # signature, or a gem without one, may define the name.
        def definer_ahead(class_name, name, owner)
          chain = Scope::ResolutionChain.for(@scope, class_name.to_s, :instance, :methods)
          unprovable! if chain.truncated? || chain.wildcard_mixin? || !settled?(chain)

          chain.search(@scope) do |entry|
            unprovable! if entry.external? || rewritten?(entry.name)

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
          suffix = "::#{segment}"
          project = [@scope.discovered_classes, @scope.in_source_constants]
          ends_with_segment = ->(name) { (name = name.to_s) == segment || name.end_with?(suffix) }
          return nil if project.any? { |table| table.each_key.any?(&ends_with_segment) }

          type
        end

        def unprovable!
          raise Unprovable
        end
      end
    end
  end
end
