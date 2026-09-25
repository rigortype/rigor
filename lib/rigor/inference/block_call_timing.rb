# frozen_string_literal: true

require_relative "../type"
require_relative "../reflection"

module Rigor
  module Inference
    # Issue #1095 — the first slice of the block call-timing summary that
    # `docs/type-specification/control-flow-analysis.md` § "Block call timing" asks for: which callees invoke
    # their block **immediately, exactly once, and before they return**.
    #
    # The fact matters for the value of the call. Since #853 a block-level `break` joins the yielding call's
    # type, unioned with what the callee returns when the block completes normally. For an arbitrary callee
    # that normal return must stay — `each` may never yield on an empty receiver. For a callee that always
    # yields exactly once before returning, a block whose normal completion is unreachable means the normal
    # return is unreachable too, so the call's value is its `break` arms alone (`bot` when there are none):
    # `[1, 2].tap { break "s" }` is `"s"`, `[1, 2].tap { raise "x" }` is `bot`.
    #
    # ## Catalogue
    #
    # Like {ClosureEscapeAnalyzer}'s `OBJECT_NON_ESCAPING` — a weaker "block is not retained" fact that `each`
    # and `map` also satisfy — this ships as a hardcoded table keyed by `(owner, method)`, where the owner is
    # the module whose declaration Ruby dispatches to. The sub-phase that replaces the escape catalogue with an
    # `RBS::Extended` call-timing effect (`rbs-extended.md` reserves the bundle slot) is expected to absorb
    # this table in the same move, which is why it is keyed by the declaring owner, the way a signature-borne
    # effect would be, rather than by the receiver's class.
    #
    # The owner is `Kernel` for all three, in CRuby (`Object.instance_method(:tap).owner`) and in the bundled
    # core RBS alike. `Object` is deliberately NOT accepted: every class inherits these methods through
    # `Object`, so a declaration that resolves to `Object` itself is a project or gem override written on top
    # of Kernel's, and that override is not known to yield exactly once.
    #
    # The summary is a pure query. It never raises on unrecognised input and answers `false` — keep the
    # `break | normal-return` union — whenever it cannot prove the call reaches the catalogued declaration.
    module BlockCallTiming
      EXACTLY_ONCE_IMMEDIATE = {
        "Kernel" => %i[tap then yield_self].freeze
      }.freeze

      CANDIDATE_NAMES = EXACTLY_ONCE_IMMEDIATE.values.flatten.uniq.freeze
      private_constant :CANDIDATE_NAMES

      # The roots a project monkey-patch would redefine the method on for every receiver at once.
      PATCHABLE_ROOTS = %w[Object Kernel BasicObject].freeze
      private_constant :PATCHABLE_ROOTS

      # A class object's own metaclass ancestry adds these ahead of `Object`, so a patch on either one
      # redefines the method for every class-object receiver.
      SINGLETON_ROOTS = %w[Class Module].freeze
      private_constant :SINGLETON_ROOTS

      # Receiver-less (or `self.` / `Kernel.`) calls that never return normally: they raise, throw, or end
      # the process. Anything else — including `loop`, whose RBS return is `bot` although a `StopIteration`
      # ends it normally ({.loop_may_complete?}) — proves nothing.
      NON_RETURNING_CALLS = %i[raise fail throw exit exit! abort].freeze
      private_constant :NON_RETURNING_CALLS

      # Issue #1107 — the nodes a `loop` body may consist of while still provably unable to raise
      # `StopIteration`: none of them dispatches a method, so nothing in the body can run code that raises.
      # Everything else — every call (operators and `[]` included), `yield`, `super`, interpolation, a splat,
      # a constant read (`const_missing`), a `rescue` — may, and declines.
      STOP_ITERATION_FREE_NODES = [
        Prism::StatementsNode, Prism::ParenthesesNode, Prism::ArgumentsNode,
        Prism::BreakNode, Prism::NextNode, Prism::RedoNode, Prism::ReturnNode,
        Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
        Prism::StringNode, Prism::SymbolNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::SelfNode,
        Prism::LocalVariableReadNode, Prism::LocalVariableWriteNode,
        Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode,
        Prism::IfNode, Prism::UnlessNode, Prism::ElseNode, Prism::AndNode, Prism::OrNode, Prism::ArrayNode
      ].freeze
      private_constant :STOP_ITERATION_FREE_NODES

      module_function

      # Issue #1107 — whether a `loop` call can complete normally although its declared return is `bot`.
      #
      # `Kernel#loop` is `() { () -> void } -> bot` in core RBS, yet it rescues a `StopIteration` its block
      # raises and returns that exception's `result` — the enumerator-draining idiom `loop { out << e.next }`
      # returns `e`'s own `each` value. So the declared `bot` holds only for a body that provably cannot raise
      # `StopIteration`: one built from {STOP_ITERATION_FREE_NODES} alone (`loop {}`, `loop { break 1 }`), in a
      # block that declares no parameters. A `&blk` block-pass has no body to prove anything about and completes
      # too.
      #
      # Gated on the spellings that reach the private `Kernel#loop` — receiver-less, `self.`, `Kernel.`,
      # `::Kernel.` — so `obj.loop { ... }` is some other method, whose declared `bot` is that author's
      # promise. A project redefinition of `loop` itself is not excluded: widening its `bot` costs precision,
      # never a false positive.
      def loop_may_complete?(call_node)
        return false unless call_node.name == :loop && kernel_spelled_receiver?(call_node.receiver)

        block = call_node.block
        return false if block.nil?
        return true unless block.is_a?(Prism::BlockNode)
        # A parameter default (`|v = e.next|`) is evaluated on every iteration, since `loop` yields no
        # arguments. Rather than walk the parameter list, any declared parameter widens.
        return true if block.parameters
        return false if block.body.nil?

        may_raise_stop_iteration?(block.body)
      end

      def may_raise_stop_iteration?(node)
        return true unless STOP_ITERATION_FREE_NODES.any? { |klass| node.is_a?(klass) }

        node.compact_child_nodes.any? { |child| may_raise_stop_iteration?(child) }
      end

      # Cheap name-only pre-gate, so a call that cannot be catalogued pays nothing further.
      def candidate_name?(method_name)
        CANDIDATE_NAMES.include?(method_name)
      end

      def exactly_once_owner?(owner_name, method_name)
        methods = EXACTLY_ONCE_IMMEDIATE[owner_name.to_s.delete_prefix("::")]
        methods ? methods.include?(method_name) : false
      end

      # Whether a call of `method_name` on `receiver_type` reaches a catalogued exactly-once declaration.
      #
      # Gated on the RESOLVED owner, not the name: a class that defines its own `tap` (in source, in a
      # project `sig/`, or through a project ancestor), a top-level `def tap` (a private `Object` method,
      # ahead of `Kernel` in every MRO) and an `Object` / `Kernel` monkey-patch all decline. A union receiver
      # qualifies only when every member does; `Dynamic` and the other carriers that name no class decline.
      def exactly_once_call?(receiver_type:, method_name:, scope:)
        return false unless candidate_name?(method_name)
        return false if scope.nil? || project_redefines_root?(method_name, scope)

        targets = receiver_targets(receiver_type)
        return false if targets.nil? || targets.empty?

        targets.all? { |class_name, kind| resolves_to_catalogue?(class_name, kind, method_name, scope) }
      rescue StandardError
        false
      end

      # Syntactic proof that a block body cannot complete normally: every path through it ends in a
      # block-level `break` (which targets the yielding call), `return`, `redo`, or a non-returning Kernel call
      # ({NON_RETURNING_CALLS}) — or in an expression that must evaluate one of those first. This is ANDed
      # with the block-return pass's `bot`, never used alone, because a `bot` can also flow out of a callee's
      # declared return that is not a promise the call never completes (`Kernel#loop` is `-> bot`, yet a
      # `StopIteration` from `e.next` ends it normally). A shape the walk does not recognise declines.
      #
      # Only unconditionally evaluated children are descended: a nested block, lambda, `def` or loop is never
      # entered (its body may not run, and it retargets `break`), a call's block is not a child the call
      # promises to run, and `&&` / `||` count only their left operand. A `begin` with `rescue` qualifies only
      # when its body and every rescue clause must exit; an `ensure` that must exit qualifies on its own.
      def never_completes_normally?(node, scope)
        case node
        when Prism::StatementsNode then node.body.any? { |statement| never_completes_normally?(statement, scope) }
        when Prism::BreakNode, Prism::ReturnNode, Prism::RedoNode, Prism::RetryNode then true
        when Prism::ParenthesesNode then never_completes_normally?(node.body, scope)
        when Prism::CallNode then call_never_returns?(node, scope)
        when Prism::IfNode, Prism::UnlessNode then conditional_never_completes?(node, scope)
        when Prism::AndNode, Prism::OrNode then never_completes_normally?(node.left, scope)
        when Prism::BeginNode then begin_never_completes?(node, scope)
        when Prism::ArrayNode then node.elements.any? { |element| never_completes_normally?(element, scope) }
        when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode
          never_completes_normally?(node.value, scope)
        else false
        end
      end

      # Deliberately coarse: ANY project definition of the name — top-level, on any class or module, either
      # side, or a `pre_eval:` patch — declines. Resolving the call-site `self`'s ancestry precisely buys
      # nothing for names this rare, and the block-return pass is no independent check here: it types a
      # self-call to an overridden `raise` as Kernel's `bot` too, so a missed override is a wrong `bot`.
      # {LastLine.reads_line?} declines on it the same way for `gets` and `readline`.
      def project_defines_anywhere?(method_name, scope)
        return true if scope.top_level_def_for(method_name)
        # `discovered_methods` withholds a plain cross-file `def` (the ADR-17 monkey-patch contract); the
        # def-node tables still carry it, on both sides.
        return true if [scope.discovered_methods, scope.discovered_def_nodes, scope.discovered_singleton_def_nodes]
                       .any? { |tables| tables.any? { |_class_name, table| table.key?(method_name) } }

        patched = scope.environment&.project_patched_methods
        !patched.nil? && patched.by_key.any? { |(_class_name, name, _kind), _entry| name == method_name }
      end

      class << self
        private

        def call_never_returns?(node, scope)
          return true if never_completes_normally?(node.receiver, scope)
          return true if node.arguments&.arguments&.any? { |argument| never_completes_normally?(argument, scope) }
          return false unless NON_RETURNING_CALLS.include?(node.name)

          kernel_spelled_receiver?(node.receiver) && !project_defines_anywhere?(node.name, scope)
        end

        # Implicit self, `self.`, or the `Kernel` module itself (`Kernel.` or the root-anchored `::Kernel.`) —
        # the spellings that reach Kernel's function.
        def kernel_spelled_receiver?(receiver)
          case receiver
          when nil, Prism::SelfNode then true
          when Prism::ConstantReadNode then receiver.name == :Kernel
          when Prism::ConstantPathNode then receiver.parent.nil? && receiver.name == :Kernel
          else false
          end
        end

        def conditional_never_completes?(node, scope)
          return true if never_completes_normally?(node.predicate, scope)

          alternative = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
          return false if node.statements.nil? || alternative.nil?

          never_completes_normally?(node.statements, scope) && branch_never_completes?(alternative, scope)
        end

        def branch_never_completes?(branch, scope)
          case branch
          when Prism::ElseNode then never_completes_normally?(branch.statements, scope)
          else never_completes_normally?(branch, scope)
          end
        end

        def begin_never_completes?(node, scope)
          return true if node.ensure_clause && never_completes_normally?(node.ensure_clause.statements, scope)
          return false unless never_completes_normally?(node.statements, scope)

          rescue_clause = node.rescue_clause
          while rescue_clause
            return false unless never_completes_normally?(rescue_clause.statements, scope)

            rescue_clause = rescue_clause.subsequent
          end
          true
        end

        def project_redefines_root?(method_name, scope)
          return true if scope.top_level_def_for(method_name)

          patched = scope.environment&.project_patched_methods
          PATCHABLE_ROOTS.any? do |root|
            scope.discovered_method?(root, method_name, :instance) ||
              patched&.lookup(class_name: root, method_name: method_name, kind: :instance)
          end
        end

        # `[class_name, :instance | :singleton]` pairs the receiver can dispatch through, or nil when some
        # part of it names no class. `Tuple` / `HashShape` project to `Array` / `Hash`, `Constant[v]` through
        # the value's class, the same projection {ClosureEscapeAnalyzer} uses.
        def receiver_targets(receiver_type)
          case receiver_type
          when Type::Union
            members = receiver_type.members.map { |member| receiver_targets(member) }
            members.any?(&:nil?) ? nil : members.flatten(1)
          when Type::Nominal then [[receiver_type.class_name, :instance]]
          when Type::Singleton then [[receiver_type.class_name, :singleton]]
          when Type::Tuple then [["Array", :instance]]
          when Type::HashShape then [["Hash", :instance]]
          when Type::Constant then [[receiver_type.value.class.name, :instance]]
          end
        end

        def resolves_to_catalogue?(class_name, kind, method_name, scope)
          return false if class_name.nil?
          return false if scope.discovered_method_through_ancestors?(class_name, method_name, kind)

          if kind == :singleton
            definition = Rigor::Reflection.singleton_method_definition(class_name, method_name, scope: scope)
            return false if singleton_ancestor_patched?(class_name, method_name, scope)

            return declared_on_catalogue?(definition, method_name)
          end

          definition = Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
          if definition
            return false if rbs_ancestor_patched?(class_name, method_name, scope)

            return declared_on_catalogue?(definition, method_name)
          end
          return false if Rigor::Reflection.rbs_class_known?(class_name, scope: scope)

          project_class_resolves_to_catalogue?(class_name, method_name, scope)
        end

        def declared_on_catalogue?(definition, method_name)
          return false if definition.nil? || !definition.respond_to?(:defined_in)

          exactly_once_owner?(definition.defined_in, method_name)
        end

        # A project class the RBS environment does not know: its project ancestry was already cleared by the
        # discovery walk, so the answer rests on the ancestors it reaches OUTSIDE the project. Each is asked
        # on its own terms; an ancestor nobody can resolve is uncertainty and declines. No external ancestor
        # at all is the implicit `< Object`, which reaches `Kernel`.
        def project_class_resolves_to_catalogue?(class_name, method_name, scope)
          return false unless scope.known_user_class?(class_name)

          scope.external_ancestor_name_candidates(class_name).all? do |candidates|
            external_ancestor_resolves_to_catalogue?(candidates, method_name, scope)
          end
        end

        def external_ancestor_resolves_to_catalogue?(candidates, method_name, scope)
          known = candidates.find { |candidate| Rigor::Reflection.rbs_class_known?(candidate, scope: scope) }
          return false if known.nil?

          definition = Rigor::Reflection.instance_method_definition(known, method_name, scope: scope)
          # A mixin whose RBS does not mention the method contributes nothing; a CLASS that lacks it is a
          # `BasicObject` lineage, where the call does not reach `Kernel` at all.
          return false if rbs_ancestor_patched?(known, method_name, scope)
          return scope.environment.rbs_module?(known) if definition.nil?

          declared_on_catalogue?(definition, method_name)
        end

        # The RBS declaration says where the method was DECLARED; a project reopening of a core ancestor
        # (`module Enumerable; def tap = :x; end`) redefines it without touching RBS, and discovery records
        # it under the ancestor's own name. So every RBS ancestor — mixins included — is asked.
        def rbs_ancestor_patched?(class_name, method_name, scope)
          names_patched?(rbs_ancestor_names(class_name, scope), method_name, :instance, scope)
        end

        # A class object dispatches through its own and its superclasses' singleton methods, then through
        # `Class`, `Module`, `Object`, `Kernel` as instance methods.
        def singleton_ancestor_patched?(class_name, method_name, scope)
          names_patched?(rbs_ancestor_names(class_name, scope), method_name, :singleton, scope) ||
            names_patched?(SINGLETON_ROOTS, method_name, :instance, scope)
        end

        def names_patched?(names, method_name, kind, scope)
          patched = scope.environment&.project_patched_methods
          names.any? do |name|
            scope.discovered_method?(name, method_name, kind) ||
              patched&.lookup(class_name: name, method_name: method_name, kind: kind)
          end
        end

        def rbs_ancestor_names(class_name, scope)
          loader = scope.environment&.rbs_loader
          loader ? loader.ancestor_names_for(class_name.to_s) : []
        end
      end
    end
  end
end
