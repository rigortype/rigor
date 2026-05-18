# frozen_string_literal: true

require_relative "../../type"
require_relative "../acceptance"
require_relative "../rbs_type_translator"
require_relative "receiver_affinity"

module Rigor
  module Inference
    module MethodDispatcher
      # Picks the RBS overload that should answer a call given the
      # caller's actual argument types. Slice 4 phase 2c shape (with
      # the v0.1.2 interface-strictness preference layered on top):
      #
      # 1. Filter overloads by positional arity (required, optional and
      #    rest_positionals are honored; required_keywords disqualify the
      #    overload because we do not yet thread keyword args through
      #    `call_arg_types`).
      # 2. **Pass 1 — strict matches first.** Among the arity-matching
      #    overloads, prefer the first one whose every (param, arg)
      #    pair returns a `yes` or `maybe` answer AND whose param
      #    types do NOT translate through `RBS::Types::Alias` /
      #    `Interface` / `Intersection`. The translator demotes those
      #    to `Dynamic[Top]`, which gradually accepts any argument —
      #    so without this preference, an alias-typed overload like
      #    `Array#[](::int) -> Elem` would beat the strict
      #    `Array#[](Range) -> Array[Elem]?` overload for a Range
      #    argument. (Surfaced during v0.1.1 self-analysis; see the
      #    "Interface-strictness on overload selection" item in
      #    `docs/ROADMAP.md`.)
      # 3. **Pass 2 — gradual fall-back.** If no fully strict overload
      #    matches, accept the first arity-and-gradual-accept match
      #    (the v0.1.1 behaviour). Alias / Interface / Intersection
      #    params still reach this pass, so call sites whose only
      #    candidate IS an alias-typed overload keep working.
      # 4. If no overload matches at all, fall back to
      #    `method_types.first` so existing call sites keep their
      #    phase 1 / 2b behavior. This preserves the fail-soft
      #    invariant of the dispatcher.
      #
      # The selector is intentionally agnostic about the dispatch kind
      # (instance vs singleton). Both kinds share the same arity and
      # acceptance shape; the difference is only in which `Definition`
      # the caller fetched.
      module OverloadSelector
        module_function

        # Canonical RBS-core aliases shipped by `core/builtin.rbs`
        # whose body is `<Nominal> | _DuckType`. Matching an
        # overload against an Integer literal should pick the
        # `(int) -> Array[Elem]` body over the `(string) -> String`
        # body because Integer satisfies `int`'s strict arm and
        # not `string`'s. The translator collapses both aliases
        # to `Dynamic[Top]` (interfaces are not structurally
        # matched yet), so a dedicated pass 1.5 between strict
        # and gradual consults this map to pick the alias whose
        # strict arm matches.
        #
        # Symbol keys are the alias names as they appear under
        # `RBS::Types::Alias#name.to_s` (the `name` is a
        # `TypeName` whose `to_s` includes the `::` prefix).
        # Values are an Array of class names whose Nominal[..]
        # form is the alias's strict-arm matcher.
        ALIAS_STRICT_NOMINALS = {
          "::int" => ["Integer"],
          "::string" => ["String"],
          "::interned" => %w[Symbol String],
          "::io" => ["IO"],
          "::encoding" => %w[Encoding String],
          "::path" => ["String"],
          "::boolean" => %w[TrueClass FalseClass]
        }.freeze
        private_constant :ALIAS_STRICT_NOMINALS

        # @param method_definition [RBS::Definition::Method]
        # @param arg_types [Array<Rigor::Type>] caller-provided types in
        #   positional order. Empty when there are no arguments.
        # @param self_type [Rigor::Type] substitute for `Bases::Self`.
        # @param instance_type [Rigor::Type] substitute for `Bases::Instance`.
        # @param type_vars [Hash{Symbol => Rigor::Type}] substitution map
        #   for class-level type variables (Slice 4 phase 2d). The
        #   selector threads it through to {RbsTypeTranslator} so
        #   parameter types like `::Array[Elem]` substitute Elem before
        #   the accepts check, instead of degrading the param to
        #   `Array[Dynamic[Top]]`.
        # @param block_required [Boolean] when `true`, only overloads
        #   that declare a block clause are considered (Slice 6 phase C
        #   sub-phase 1). The fallback also prefers a block-bearing
        #   overload over `method_types.first`. When `false` (the
        #   Slice 4 phase 2c default) the selector behaves exactly as
        #   before: `find` over arity-compatible overloads, falling
        #   back to the first declaration.
        # @return [RBS::MethodType, nil] the chosen overload, or nil
        #   when the definition has no method types at all.
        def select(method_definition, arg_types:, self_type:, instance_type:, type_vars: {}, block_required: false,
                   environment: nil)
          overloads = method_definition.method_types
          return nil if overloads.empty?

          # `rigor:v1:param: <name> <refinement>` annotations on
          # this method override the RBS-declared parameter type
          # at the matching name. The map is consumed inside
          # `accepts_param?` so overload selection sees the
          # tighter type when filtering candidates by argument
          # compatibility.
          param_overrides = RbsExtended.param_type_override_map(method_definition, environment: environment)

          # Pre-sort: demote overloads whose param class is a
          # disjoint sibling of the receiver class (e.g.
          # `Integer#+(BigDecimal) -> BigDecimal` from the
          # `bigdecimal` RBS reopen). Honors the coerce
          # convention so `5 + ?` for unknown `?` resolves to
          # the receiver-class-preserving arm rather than an
          # arbitrary sibling-class arm that only wins by
          # overload-list position.
          overloads = ReceiverAffinity.reorder(overloads, self_type: self_type, environment: environment)

          match = run_selection_passes(
            overloads, arg_types: arg_types, self_type: self_type, instance_type: instance_type,
                       type_vars: type_vars, block_required: block_required, param_overrides: param_overrides
          )
          return match if match
          return overloads.find { |mt| overload_has_block?(mt) } if block_required

          overloads.first
        end

        def overload_has_block?(method_type)
          method_type.respond_to?(:block) && method_type.block
        end

        class << self
          private

          # Three-pass overload search:
          # - Pass 1 (strict): skipped when any arg is
          #   `Dynamic[Top]`, because gradual acceptance against
          #   an untyped arg accepts every param indiscriminately
          #   and would let pass 1 lock in an arbitrary strict
          #   overload (e.g. `Regexp#=~(nil) -> nil` over the
          #   `(::interned?) -> Integer?` overload).
          # - Pass 1.5 (alias-resolved): consults each `RBS::Types::Alias`'s
          #   strict arm so e.g. `Array#*(int)` wins over the
          #   `Array#*(string) -> String` overload for Integer args.
          # - Pass 2 (gradual): the original gradual matcher so
          #   overloads that legitimately rely on duck-typed
          #   params still resolve when nothing stricter applies.
          def run_selection_passes(overloads, arg_types:, self_type:, instance_type:, type_vars:, block_required:,
                                   param_overrides:)
            shared = {
              arg_types: arg_types, self_type: self_type, instance_type: instance_type,
              type_vars: type_vars, block_required: block_required, param_overrides: param_overrides
            }
            find_matching_overload(overloads, **shared, strict: true) ||
              find_matching_overload_via_aliases(overloads, arg_types: arg_types, block_required: block_required) ||
              find_matching_overload(overloads, **shared, strict: false)
          end

          # rubocop:disable Metrics/ParameterLists
          def find_matching_overload(overloads, arg_types:, self_type:, instance_type:, type_vars:, block_required:,
                                     param_overrides:, strict:)
            return nil if strict && arg_types.any? { |t| untyped_arg?(t) }

            overloads.find do |method_type|
              next false if block_required && !OverloadSelector.overload_has_block?(method_type)
              next false if strict && !strictly_typed_params?(method_type, arg_types.size)

              matches?(
                method_type,
                arg_types,
                self_type: self_type,
                instance_type: instance_type,
                type_vars: type_vars,
                param_overrides: param_overrides
              )
            end
          end
          # rubocop:enable Metrics/ParameterLists

          # Treats the literal `untyped` carrier (`Dynamic[Top]`)
          # as too imprecise to drive a strict-pass match. Other
          # `Dynamic`-wrapped types with a concrete static facet
          # carry enough information to pick a sensible overload.
          def untyped_arg?(type)
            type.is_a?(Type::Dynamic) && type.static_facet.is_a?(Type::Top)
          end

          # Pass 1.5: for arity-compatible overloads whose every
          # positional param is either a strict nominal OR a
          # well-known core alias (`int` / `string` / `interned`
          # / etc.), check the arg against the alias's STRICT
          # arm. An Integer literal arg matches `int` here but
          # not `string`, so `Array#*(int)` wins over the
          # `Array#*(string) -> String` overload — even though
          # both translate to `Dynamic[Top]` at the param level.
          # Only fires when EVERY positional param has a known
          # alias-or-strict shape; otherwise gradual matching
          # takes over.
          def find_matching_overload_via_aliases(overloads, arg_types:, block_required:)
            overloads.find do |method_type|
              next false if block_required && !OverloadSelector.overload_has_block?(method_type)

              fun = method_type.type
              next false unless arity_compatible?(fun, arg_types.size)

              params = positional_params_for(fun, arg_types.size)
              next false unless params.size == arg_types.size

              params.zip(arg_types).all? { |param, arg| alias_param_accepts?(param.type, arg) }
            end
          end

          # Checks the param's RBS type against an arg using
          # alias-strict-arm matching. Optional / Union wrappers
          # are flattened; alias resolution is one level deep
          # (the canonical core aliases all have non-alias
          # strict arms).
          def alias_param_accepts?(rbs_type, arg)
            nominal_names = strict_nominal_names_for(rbs_type)
            return false if nominal_names.nil? || nominal_names.empty?

            nominal_names.any? do |class_name|
              result = Type::Combinator.nominal_of(class_name).accepts(arg, mode: :gradual)
              result.yes? || result.maybe?
            end
          end

          # Returns the candidate class names a param's RBS type
          # accepts under alias-resolved strict matching, or nil
          # when the shape cannot be reduced to a closed set of
          # nominals (e.g. an Interface or an unrecognised alias).
          def strict_nominal_names_for(rbs_type)
            case rbs_type
            when RBS::Types::ClassInstance
              [rbs_type.name.to_s.delete_prefix("::")]
            when RBS::Types::Alias
              ALIAS_STRICT_NOMINALS[rbs_type.name.to_s]
            when RBS::Types::Optional
              strict_nominal_names_for(rbs_type.type)
            when RBS::Types::Union
              parts = rbs_type.types.map { |t| strict_nominal_names_for(t) }
              return nil if parts.any?(&:nil?)

              parts.flatten
            end
          end

          # Returns true when every positional param the call
          # site engages translates to a non-`Dynamic[Top]`
          # carrier. Alias / Interface / Intersection RBS types
          # all degrade to `Dynamic[Top]` per the translator's
          # current shape — those gradually accept any arg, so
          # an overload that includes one would beat strictly-
          # typed alternatives in pass 2 of the selector.
          def strictly_typed_params?(method_type, actual_count)
            fun = method_type.type
            return false unless arity_compatible?(fun, actual_count)

            params = positional_params_for(fun, actual_count)
            params.all? { |param| !alias_or_interface_param?(param.type) }
          end

          # Recursive: an Optional / Union wrapper is strict iff
          # every member is strict. Type args of a ClassInstance
          # are NOT walked — `Range[::int]` is a Range carrier
          # at the param level; the alias only colours the
          # element type, which is checked separately when the
          # element is actually accessed.
          #
          # `RBS::Types::Bases::Any` (the explicit `untyped`
          # keyword) is treated like Alias / Interface /
          # Intersection — both translate to `Dynamic[Top]`,
          # both gradually accept anything. A `(untyped) -> T`
          # catch-all overload that comes after the strictly-
          # typed ones must lose pass 1 so the typed overloads
          # win when their param actually fits the arg.
          def alias_or_interface_param?(rbs_type)
            case rbs_type
            when RBS::Types::Alias, RBS::Types::Interface,
                 RBS::Types::Intersection, RBS::Types::Bases::Any
              true
            when RBS::Types::Optional
              alias_or_interface_param?(rbs_type.type)
            when RBS::Types::Union
              rbs_type.types.any? { |t| alias_or_interface_param?(t) }
            else
              false
            end
          end

          def matches?(method_type, arg_types, self_type:, instance_type:, type_vars:, param_overrides:)
            return false if method_type.respond_to?(:type_params) && rejects_keyword_required?(method_type)

            fun = method_type.type
            return false unless arity_compatible?(fun, arg_types.size)

            params = positional_params_for(fun, arg_types.size)
            params.zip(arg_types).all? do |param, arg|
              accepts_param?(
                param,
                arg,
                self_type: self_type,
                instance_type: instance_type,
                type_vars: type_vars,
                param_overrides: param_overrides
              )
            end
          end

          # Slice 4 phase 2c does not pass keyword arguments through the
          # call site (caller passes only positional `arg_types`). An
          # overload that requires keywords is therefore not a viable
          # candidate; we skip it instead of forcing a fallback.
          def rejects_keyword_required?(method_type)
            fun = method_type.type
            return false unless fun.respond_to?(:required_keywords)

            !fun.required_keywords.empty?
          end

          def arity_compatible?(fun, actual_count)
            min_arity = fun.required_positionals.size + fun.trailing_positionals.size
            return false if actual_count < min_arity

            return true if fun.rest_positionals

            max_arity = min_arity + fun.optional_positionals.size
            actual_count <= max_arity
          end

          # Builds the list of formal parameter declarations to compare
          # against the actual arguments, in positional order: required
          # first, then as many optionals as needed, then trailing
          # required. Rest_positionals consumes the remainder; we
          # repeat its single declaration for each absorbed argument.
          def positional_params_for(fun, actual_count)
            required = fun.required_positionals
            optional = fun.optional_positionals
            rest = fun.rest_positionals
            trailing = fun.trailing_positionals

            head = required.dup
            optional_needed = [actual_count - head.size - trailing.size, 0].max
            head.concat(optional.first(optional_needed))

            absorbed_by_rest = actual_count - head.size - trailing.size
            head.concat([rest] * absorbed_by_rest) if rest && absorbed_by_rest.positive?

            head.concat(trailing)
            head
          end

          def accepts_param?(param, arg, self_type:, instance_type:, type_vars:, param_overrides:)
            param_type = param_overrides[param.name] || RbsTypeTranslator.translate(
              param.type,
              self_type: self_type,
              instance_type: instance_type,
              type_vars: type_vars
            )
            result = param_type.accepts(arg, mode: :gradual)
            result.yes? || result.maybe?
          end
        end
      end
    end
  end
end
