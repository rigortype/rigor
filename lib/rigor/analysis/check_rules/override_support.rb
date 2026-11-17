# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../../scope"
require_relative "../../type"
require_relative "../../inference/definer_resolution"
require_relative "../../inference/rbs_type_translator"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — the resolution the three Liskov override rules share, and the helpers {ReturnType} shares
      # with them: the authored-override walk ({.resolve_authored_override}), the first ancestor an override
      # reaches ({.overridden_ancestors_start}), the generic-instantiation map
      # ({.ancestor_instantiation_type_vars}), {.defined_on?}, {.declared_return_union} and {.dynamic_top?}.
      #
      # Called by {OverrideVisibility}, {OverrideReturnWidened}, {OverrideParamNarrowed} and {ReturnType}; it
      # calls nothing in `CheckRules`. The last three stay here: the override rules and the walk above call them too.
      module OverrideSupport
        module_function

        # ADR-35 WD10 (issue #1716) — the object-lifecycle hooks the three override rules skip. `initialize` is
        # reached through `Class#new` on the class the caller names, and the copy hooks are handed an instance
        # of the receiver's own class by `dup` / `clone`, so neither is called with the PARENT's declared
        # arguments through a parent-typed reference; `new` / `dup` / `clone` discard all four returns.
        LIFECYCLE_HOOKS = %i[initialize initialize_copy initialize_dup initialize_clone].freeze

        # `type_vars:` — ADR-35 WD9 tier 1. When the caller supplies a generic-instantiation
        # substitution map (parent-side, keyed by the parent class's declared type-parameter names),
        # a `-> T` return is translated at its instantiated type (`-> Integer`) rather than degrading
        # to `Dynamic[Top]`. The default empty map is the pre-WD9 behaviour, under which any type
        # variable degrades to `Dynamic[Top]` and the rule stays silent.
        def declared_return_union(method_def, environment, type_vars: {})
          translated = method_def.method_types.filter_map do |mt|
            Inference::RbsTypeTranslator.translate(
              mt.type.return_type,
              self_type: nil, instance_type: nil, type_vars: type_vars,
              alias_expander: environment&.rbs_loader
            )
          rescue StandardError
            nil
          end
          return nil if translated.empty?

          translated.size == 1 ? translated.first : Type::Combinator.union(*translated)
        end

        def dynamic_top?(type)
          type.is_a?(Type::Dynamic) || (type.respond_to?(:top?) && type.top?.yes?)
        end

        # The project ancestors whose definitions `class_name`'s own `def` OVERRIDES are the entries AFTER the
        # class on its {Scope::ResolutionChain}, nearest first; {#nearest_ancestor_visibility} and
        # {#nearest_ancestor_method_def} each read the first of them that answers their question through
        # `Inference::DefinerResolution` (ADR-119 C1c), `from:` the position after the class. Both are instance
        # side only: the singleton override rules do not exist, and the singleton side's own read lands with
        # ADR-119's singleton design.
        #
        # Issue #1568 — the walk this replaced was breadth-first from the class's direct ancestors, and those
        # include the modules the class PREPENDS. A prepended module sits BEFORE the class in Ruby's order: its
        # `def` overrides the class's, not the other way round, so `prepend P` with a public `P#foo` and a
        # private `C#foo` reported `C#foo` as reducing `P#foo`'s visibility. It also reached `Base` before a
        # module included through an included module (#1567's order).
        #
        # ADR-119 WD3 — for the two override lints *absent* always counts: a chain that does not settle (a mixin
        # whose position the tables cannot vouch for, a fork whose worlds disagree, a conditional or
        # block-scoped `include`), or an external ancestor ahead of the parent that RBS does not know or knows
        # and declares the name in, is `UNKNOWN`, and the lint stays silent rather than answer from the
        # breadth-first order the walk used before (`Scope::ResolutionChain::MasterOrder`) where the order is
        # not known. The two lints read only the `[owner, value]` of a `Known`.
        #
        # ADR-46 slice 3 — an ancestor the project does not declare ends the walk's reach into it, and a class
        # defined LATER under that name would change the answer; `DefinerResolution` files the negative class
        # edge of each external entry it tests.
        def overridden_ancestors_start(scope, class_name)
          # Issue #2979 — past the entries of the names bound to the same class (`K = Struct.new("Named", …)`):
          # a `def` there redefines the class's method rather than overriding an ancestor's.
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :instance, :methods)
          chain.ancestors_start(scope, class_name.to_s)
        end

        # The authored-override resolution shared by the Liskov override rules
        # (`def.override-return-widened` and `def.override-param-narrowed`): the def must be an instance
        # method whose own class declares it in RBS, and a project-discovered ancestor must also declare
        # it. Returns `[scope, override_method, parent_class, parent_method]`, or nil (the rule does not
        # fire) when any gate is unmet.
        def resolve_authored_override(def_node, scope_index)
          return nil unless def_node.receiver.nil? # instance methods only (singleton: follow-on)
          return nil if LIFECYCLE_HOOKS.include?(def_node.name) # ADR-35 WD10: outside substitutability

          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          class_name = self_type.class_name.to_s
          method_name = def_node.name

          override_method = safe_instance_method_definition(class_name, method_name, scope)
          return nil if override_method.nil?
          return nil unless defined_on?(override_method, class_name)

          parent = nearest_ancestor_method_def(scope, class_name, method_name)
          return nil if parent.nil?

          parent_class, parent_method = parent
          [scope, override_method, parent_class, parent_method]
        end

        # `[defining_class, RBS::Definition::Method]` for the nearest project-discovered ancestor whose
        # RBS declares `method_name` (not the starting class's own declaration), or nil.
        def nearest_ancestor_method_def(scope, class_name, method_name)
          from = overridden_ancestors_start(scope, class_name)
          return nil if from.nil?

          passed_owners = []
          case Inference::DefinerResolution.resolve(scope, class_name, method_name, :instance,
                                                    question: :override, from: from) do |ancestor|
                 override_parent_answer(scope, ancestor, method_name, passed_owners)
               end
          in Inference::DefinerResolution::Known(owner:, answer:)
            # The nearest declaration must be the one that answers: an ancestor asked past for a project
            # owner the walk never reached (one the Ruby chain does not hold) leaves the rule silent.
            unless answer.last == RBS_ONLY_OWNER ||
                   passed_owners.any? { |passed| passed != normalize_class_name(owner) }
              method_def = safe_instance_method_definition(owner, method_name, scope)
              method_def && [owner, method_def]
            end
          in Inference::DefinerResolution::UNKNOWN # the case/in contract needs one arm per answer
            nil
          in Inference::DefinerResolution::ABSENT # rubocop:disable Lint/DuplicateBranch -- see above
            nil
          end
        end

        # The answer an RBS-only owner gives the override walk: it ends the walk, and the rule stays silent.
        RBS_ONLY_OWNER = :rbs_only_owner
        private_constant :RBS_ONLY_OWNER

        # One project ancestor's answer to the override walk. The signature text is the answer two worlds
        # compare: an `RBS::Definition::Method` has no structural equality of its own. Only an ancestor whose
        # own RBS declares the method answers with it (#3046). One that inherits the declaration from another
        # project class or module is asked past, so that owner answers at its own entry; the owner is recorded
        # in `passed_owners`, which the answering owner must match. One that inherits it from an RBS-only owner
        # the project chain cannot see ends the walk silent ({RBS_ONLY_OWNER}): that owner is the nearest
        # declaration, and RBS-only ancestors are #130's.
        def override_parent_answer(scope, ancestor, method_name, passed_owners)
          method_def = safe_instance_method_definition(ancestor, method_name, scope)
          return nil if method_def.nil?
          return method_def.method_types.map(&:to_s) if declared_by?(method_def, ancestor)

          owner = method_def.implemented_in || method_def.defined_in
          return RBS_ONLY_OWNER unless owner && scope.discovered_classes.key?(normalize_class_name(owner))

          passed_owners << normalize_class_name(owner)
          nil
        end

        # True when `ancestor`'s own RBS declares `method_def`: on its body, or through an interface it
        # includes itself (RBS records the including class as `implemented_in`).
        def declared_by?(method_def, ancestor)
          return true if defined_on?(method_def, ancestor)
          return false unless method_def.defined_in&.interface?

          normalize_class_name(method_def.implemented_in) == normalize_class_name(ancestor)
        end

        def safe_instance_method_definition(class_name, method_name, scope)
          Reflection.instance_method_definition(class_name, method_name, scope: scope)
        rescue StandardError
          nil
        end

        # True when `method_def`'s RBS declaration lives on `class_name` itself (rather than being
        # inherited from an ancestor).
        def defined_on?(method_def, class_name)
          defined_in = method_def.defined_in
          return false if defined_in.nil?

          normalize_class_name(defined_in.to_s) == normalize_class_name(class_name)
        end

        def normalize_class_name(name)
          name.to_s.delete_prefix("::")
        end

        # ADR-35 WD9 tier 1 — generic-instantiation-aware comparison. Builds the substitution map
        # `{ parent_type_param_name => instantiated Rigor::Type }` for the parent contract as the
        # overriding subclass instantiates it (RBS `class Sub < Parent[Concrete]` / `include
        # _Iface[Concrete]`). Mirrors the ADR-4 Phase 2d dispatcher zip (`build_type_vars`): the
        # parent's declared type-parameter names zipped against the subclass-side instantiation args.
        #
        # Returns `{}` — restoring the pre-WD9 behaviour under which any parent type variable degrades
        # to `Dynamic[Top]` and the rule stays silent — whenever the subclass does not instantiate the
        # ancestor generically, the RBS definition cannot be built, arities disagree, or an argument
        # fails to translate. This is the FP-safety contract: substitution only ever *adds* precision
        # (a `-> T` compared at `-> Integer`); an unbound / unresolved generic keeps degrading to
        # silence, never a false `:no`.
        def ancestor_instantiation_type_vars(scope, parent_class)
          self_type = scope.self_type
          return {} unless self_type.respond_to?(:class_name)

          args = ancestor_instantiation_args(scope, self_type.class_name.to_s, parent_class)
          return {} if args.nil? || args.empty?

          param_names = Reflection.class_type_param_names(parent_class, scope: scope)
          return {} if param_names.empty? || param_names.size != args.size

          translated = args.map do |arg|
            Inference::RbsTypeTranslator.translate(
              arg, self_type: nil, instance_type: nil, type_vars: {},
                   alias_expander: scope.environment&.rbs_loader
            )
          rescue StandardError
            nil
          end
          return {} if translated.any?(&:nil?)

          param_names.zip(translated).to_h
        end

        # The RBS type arguments the subclass applies to `parent_class` in its ancestry, or nil when
        # the subclass has no RBS definition or does not name that ancestor. Reads the resolved
        # instance-ancestor list (`RBS::Definition#ancestors`), whose `Ancestor::Instance` entries carry
        # the instantiation `.args` for each superclass / included module. Fail-soft: any RBS build
        # error yields nil, which the caller treats as "no instantiation" and degrades to silence.
        def ancestor_instantiation_args(scope, subclass_name, parent_class)
          definition = Reflection.instance_definition(subclass_name, scope: scope)
          return nil if definition.nil?

          target = normalize_class_name(parent_class)
          ancestor = definition.ancestors.ancestors.find do |anc|
            anc.respond_to?(:args) && normalize_class_name(anc.name.to_s) == target
          end
          ancestor&.args
        rescue ::RBS::BaseError, StandardError
          nil
        end

        private_class_method :nearest_ancestor_method_def, :override_parent_answer, :declared_by?,
                             :safe_instance_method_definition, :normalize_class_name, :ancestor_instantiation_args
      end
    end
  end
end
