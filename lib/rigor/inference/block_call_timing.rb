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

      module_function

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

      class << self
        private

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
            return declared_on_catalogue?(definition, method_name)
          end

          definition = Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
          return declared_on_catalogue?(definition, method_name) if definition
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
          return scope.environment.rbs_module?(known) if definition.nil?

          declared_on_catalogue?(definition, method_name)
        end
      end
    end
  end
end
