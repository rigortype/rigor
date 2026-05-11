# frozen_string_literal: true

require_relative "../../type"
require_relative "../acceptance"
require_relative "../rbs_type_translator"

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
      #    `docs/MILESTONES.md`.)
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
      module OverloadSelector # rubocop:disable Metrics/ModuleLength
        module_function

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
        # rubocop:disable Metrics/ParameterLists
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

          # Pass 1: prefer overloads whose param types stay strict —
          # no translator-induced `Dynamic[Top]` from Alias /
          # Interface / Intersection. The pass is skipped
          # entirely when any arg is `Dynamic[Top]` (literally
          # `untyped`), because gradual acceptance against an
          # untyped arg accepts every param indiscriminately and
          # would let pass 1 lock in an arbitrary strict overload
          # (e.g. `Regexp#=~(nil) -> nil` over the
          # `(::interned?) -> Integer?` overload). Pass 2 falls
          # back to the original gradual matcher so overloads
          # that legitimately rely on duck-typed params still
          # resolve when nothing stricter applies.
          match = find_matching_overload(
            overloads,
            arg_types: arg_types,
            self_type: self_type,
            instance_type: instance_type,
            type_vars: type_vars,
            block_required: block_required,
            param_overrides: param_overrides,
            strict: true
          ) || find_matching_overload(
            overloads,
            arg_types: arg_types,
            self_type: self_type,
            instance_type: instance_type,
            type_vars: type_vars,
            block_required: block_required,
            param_overrides: param_overrides,
            strict: false
          )
          return match if match
          return overloads.find { |mt| overload_has_block?(mt) } if block_required

          overloads.first
        end
        # rubocop:enable Metrics/ParameterLists

        def overload_has_block?(method_type)
          method_type.respond_to?(:block) && method_type.block
        end

        class << self
          private

          # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
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
          # rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          # Treats the literal `untyped` carrier (`Dynamic[Top]`)
          # as too imprecise to drive a strict-pass match. Other
          # `Dynamic`-wrapped types with a concrete static facet
          # carry enough information to pick a sensible overload.
          def untyped_arg?(type)
            type.is_a?(Type::Dynamic) && type.static_facet.is_a?(Type::Top)
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

          # rubocop:disable Metrics/ParameterLists
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
          # rubocop:enable Metrics/ParameterLists

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

          # rubocop:disable Metrics/ParameterLists
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
          # rubocop:enable Metrics/ParameterLists
        end
      end
    end
  end
end
