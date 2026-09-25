# frozen_string_literal: true

require_relative "../../type"
require_relative "../acceptance"
require_relative "../rbs_type_translator"
require_relative "alias_strict_nominals"
require_relative "facet_distribution"
require_relative "proven_overload"
require_relative "receiver_affinity"

module Rigor
  module Inference
    module MethodDispatcher
      # Picks the RBS overload that should answer a call given the caller's actual argument types. Slice 4
      # phase 2c shape (with the v0.1.2 interface-strictness preference layered on top):
      #
      # 1. Filter overloads by positional arity (required, optional and rest_positionals are honored;
      #    required_keywords disqualify the overload because we do not yet thread keyword args through
      #    `call_arg_types`).
      # 1a. **Pass 0 — proven, in declared order (#1344).** With only plain-value arguments, the first
      #    overload they do not rule out wins outright when each of its params names its argument's own
      #    class and accepts it with a `yes`; every later pass reads the receiver-affinity order instead.
      # 2. **Pass 1 — strict matches first.** Among the arity-matching overloads, prefer the first one
      #    whose every (param, arg) pair returns a `yes` or `maybe` answer AND whose param types do NOT
      #    translate through `RBS::Types::Alias` / `Interface` / `Intersection`. The translator demotes
      #    those to `Dynamic[Top]`, which gradually accepts any argument — so without this preference, an
      #    alias-typed overload like `Array#[](::int) -> Elem` would beat the strict
      #    `Array#[](Range) -> Array[Elem]?` overload for a Range argument.
      # 3. **Pass 2 — gradual fall-back.** If no fully strict overload matches, accept the first
      #    arity-and-gradual-accept match (the v0.1.1 behaviour). Alias / Interface / Intersection params
      #    still reach this pass, so call sites whose only candidate IS an alias-typed overload keep
      #    working. One exclusion: an `untyped` argument does NOT gradually match a value-pinning param
      #    (`nil` / literal types — carriers that admit only specific values). Those overloads carry
      #    value-precise returns (`Kernel#Array: (nil) -> []`, `Regexp#=~: (nil) -> nil`) that would
      #    otherwise win purely by list position and inject false constants into the flow; they remain
      #    selectable when the argument PROVES the value (strict pass) or when no other overload matches
      #    (step 4's fallback picks the first overload regardless).
      # 4. If no overload matches at all, fall back to `method_types.first` so existing call sites keep
      #    their phase 1 / 2b behavior. This preserves the fail-soft invariant of the dispatcher.
      #
      # The selector is intentionally agnostic about the dispatch kind (instance vs singleton). Both kinds
      # share the same arity and acceptance shape; the difference is only in which `Definition` the caller
      # fetched.
      module OverloadSelector
        module_function

        # `ALIAS_STRICT_NOMINALS`, the alias-strict pass's table, lives in `alias_strict_nominals.rb`.

        # @param arg_types — caller-provided types in positional order. Empty when
        #   there are no arguments.
        # @param self_type — substitute for `Bases::Self`.
        # @param instance_type — substitute for `Bases::Instance`.
        # @param type_vars — substitution map for class-level type variables
        #   (Slice 4 phase 2d). The selector threads it through to {RbsTypeTranslator} so parameter types
        #   like `::Array[Elem]` substitute Elem before the accepts check, instead of degrading the param
        #   to `Array[Dynamic[Top]]`.
        # @param block_required — when `true`, only overloads that declare a block clause are
        #   considered (Slice 6 phase C sub-phase 1). The fallback also prefers a block-bearing overload
        #   over `method_types.first`. When `false` (the Slice 4 phase 2c default) the selector behaves
        #   exactly as before: `find` over arity-compatible overloads, falling back to the first
        #   declaration.
        # @return the chosen overload, or nil when the definition has no method
        #   types at all.
        def select(method_definition, **) = select_candidates(method_definition, **).first

        # Issue #521 — like {.select}, but when an imprecise argument (`Dynamic[Top]`, or since #1021 a
        # union with a `Dynamic[Top]` member) reaches the gradual pass it returns EVERY gradually-matching
        # overload instead of pinning the first. An untyped argument accepts every param
        # indiscriminately, so "first gradual match" is decided by overload-list
        # position, not by types — `[true] * n` with an untyped `n` pinned `Array#*(string) -> String`
        # and answered a wrong precise type the runtime can contradict. The caller unions the candidates'
        # returns, which contains the truth whichever overload the runtime takes. Every other path (strict,
        # alias-resolved, typed-gradual, arity fallback) still yields exactly one candidate, so `select`
        # keeps its historical single answer.
        #
        # @return matching overloads; empty when the definition declares none.
        def select_candidates(method_definition, arg_types:, **)
          FacetDistribution.select(arg_types) do |args, member|
            select_declared(method_definition, arg_types: args, member: member, **)
          end
        end

        # The selection proper. A member-wise call (`member:`, see `FacetDistribution.select`) answers only a genuine
        # match, never the first-overload fallback.
        # rubocop:disable-next Metrics/ParameterLists -- the public keyword surface plus the member-wise flag.
        def select_declared(method_definition, arg_types:, self_type:, instance_type:, type_vars: {},
                            block_required: false, environment: nil, member: false)
          declared = method_definition.method_types
          return [] if declared.empty?

          # `rigor:v1:param: <name> <refinement>` annotations on this method override the RBS-declared
          # parameter type at the matching name. The map is consumed inside `accepts_param?` so overload
          # selection sees the tighter type when filtering candidates by argument compatibility.
          param_overrides = RbsExtended.param_type_override_map(method_definition, environment: environment)

          # Pre-sort: demote overloads whose param class is a disjoint sibling of the receiver class (e.g.
          # `Integer#+(BigDecimal) -> BigDecimal` from the `bigdecimal` RBS reopen). Honors the coerce
          # convention so `5 + ?` for unknown `?` resolves to the receiver-class-preserving arm rather than
          # an arbitrary sibling-class arm that only wins by overload-list position. The proven pass keeps
          # the declared order (see `run_selection_passes`).
          overloads = ReceiverAffinity.reorder(declared, self_type: self_type, environment: environment)

          # One keyword bundle for the pass pipeline (see `run_selection_passes`); a block retry rebuilds it
          # with the block flag cleared. Built once and passed positionally -- the previous lambda plus a
          # `**shared` splat per pass allocated three objects per selection (#775).
          shared = { arg_types: arg_types, self_type: self_type, instance_type: instance_type,
                     type_vars: type_vars, block_required: block_required, param_overrides: param_overrides,
                     alias_expander: environment&.rbs_loader, environment: environment, member: member }

          matches = run_selection_passes(declared, overloads, shared)
          return matches unless matches.empty?

          # A block at the call site that no block-declaring overload matched: Ruby ignores a block handed
          # to a method that never yields it, so retry treating the block as ignorable rather than failing
          # the dispatch. Without this, a block-bearing call to a method whose RBS declares no block (e.g.
          # `define_command(:x) do … end` against `def define_command: (Symbol) -> Symbol`) degraded to
          # `Dynamic[Top]` — and on a self-send suppressed the whole method's return type.
          if block_required
            matches = run_selection_passes(declared, overloads, shared.merge(block_required: false))
            return matches unless matches.empty?
          end
          return [] if member

          # No (usable) block at the call site: prefer an overload that does not REQUIRE a block over
          # `overloads.first`. Methods like `Array#filter` / `Enumerable#map` declare the block-bearing
          # overload first (`() { ... } -> Array[Elem]`) and the bare-call overload second
          # (`() -> Enumerator[...]`). Without this, a no-block `[1, 2].filter` would adopt the block
          # overload's `Array[Elem]` return when the call actually yields an `Enumerator`.
          [overloads.find { |mt| !overload_requires_block?(mt) } || overloads.first]
        end

        def overload_has_block?(method_type)
          method_type.respond_to?(:block) && method_type.block
        end

        # True when the overload declares a block that the caller MUST supply (`{ ... }` in RBS). An
        # optional block (`?{ ... }`) does NOT count — that overload is a valid match for a block-less
        # call.
        def overload_requires_block?(method_type)
          block = overload_has_block?(method_type)
          !!block && block.required
        end

        class << self
          private

          # Overload search after pass 0 (`find_proven_overload`):
          # - Pass 1 (strict): skipped when any arg is imprecise (`imprecise_arg?`), because gradual
          #   acceptance against an untyped arg accepts every param indiscriminately and would let pass 1
          #   lock in an arbitrary strict overload (e.g. `Regexp#=~(nil) -> nil` over the
          #   `(::interned?) -> Integer?` overload).
          # - Pass 1.5 (alias-resolved): consults each `RBS::Types::Alias`'s strict arm so e.g.
          #   `Array#*(int)` wins over the `Array#*(string) -> String` overload for Integer args.
          # - Pass 2 (gradual): the original gradual matcher so overloads that legitimately rely on
          #   duck-typed params still resolve when nothing stricter applies.
          # `shared` is the caller-assembled keyword bundle for `find_matching_overload` — hash-shaped
          # because the pass pipeline forwards it twice and RuboCop's parameter-list budget is real.
          #
          # Pass 0 (#1344) comes first and reads the overloads in declared order; every later pass reads them
          # in receiver-affinity order (`ReceiverAffinity`). RBS resolves two arms that both take an argument by
          # declaration order: `Rational#+` declares `(Float) -> Float` before `(Numeric) -> Rational`, and the
          # affinity order, which moves the `(Numeric)` arm first, typed `Rational(1, 2) + 0.5` as `Rational`
          # where Ruby answers `1.0`. The affinity order stays for every call pass 0 declines: read in declared
          # order, the strict pass let the `bigdecimal` reopen's `(BigDecimal) -> BigDecimal` arm, which it
          # matches on a `maybe`, take `Integer#+` of a `bot`, a `Dynamic[Integer | Float | …]` or an
          # unloadable class (612 call sites across the survey corpus).
          def run_selection_passes(declared, overloads, shared)
            # Unreordered, pass 0 can only pick what the strict pass picks, so it is skipped (#1344's allocations).
            proven = find_proven_overload(declared, shared) unless overloads.equal?(declared)
            strict = proven || find_matching_overload(overloads, shared, strict: true)
            return strict unless strict.empty?

            alias_hit = find_matching_overload_via_aliases(
              overloads, arg_types: shared[:arg_types], block_required: shared[:block_required]
            )
            return [alias_hit] if alias_hit

            # Pass 2, array-valued. With every argument carrying real type information the first gradual
            # match keeps its historical single-winner contract. With an imprecise argument in play the
            # matches are indistinguishable by types — position alone would pick — so ALL of them come back
            # and the dispatch layer unions their returns (#521).
            matches = find_matching_overload(overloads, shared, strict: false)
            return matches.first(1) unless shared[:arg_types].any? { |t| imprecise_arg?(t) }

            matches
          end

          # Pass 0. With every argument a plain value (a `Constant`, or a `Nominal` with no type arguments), the
          # first overload in declared order that the arguments do not rule out is the one RBS would take, and
          # the pass takes it only when that is certain: every parameter is a lone class naming its argument's
          # own class, and accepts it with a `yes`. Any doubt declines to the affinity-ordered passes. A `maybe`
          # is doubt — the analyzer process cannot load a project class, so a declared `(Base)` only maybe
          # takes a `Sub`, and taking a later `(top)` arm instead typed the call wrong. So is a union or
          # supertype parameter, which takes the argument through a declaration upstream RBS can get wrong:
          # `Rational#divmod`'s `(Integer | Float | Rational) -> [Integer, Rational]` for a Float remainder.
          def find_proven_overload(declared, shared)
            args = shared[:arg_types]
            return nil unless ProvenOverload.applies?(args)

            index = declared.index { |mt| engages_block_shape?(mt, shared[:block_required]) && matches?(mt, shared) }
            first = index && declared[index]
            proven = first && strictly_typed_params?(first, args.size) && matches?(first, shared, strict: :proven)
            [first] if proven && !ProvenOverload.contested?(declared, index, args, shared[:environment])
          end

          # The shared "no overload matched" answer; every consumer only reads the list.
          NO_MATCH = [].freeze
          private_constant :NO_MATCH

          # `shared` is the keyword bundle `select_candidates` assembled (arg_types, self_type, instance_type,
          # type_vars, block_required, param_overrides, alias_expander).
          def find_matching_overload(overloads, shared, strict:)
            arg_types = shared[:arg_types]
            return NO_MATCH if strict && arg_types.any? { |t| imprecise_arg?(t) }

            block_required = shared[:block_required]
            # Strict keeps its historical first-match short-circuit (a dispatch hot path); the gradual
            # pass needs the full candidate list for the #521 union.
            if strict
              found = overloads.find do |method_type|
                engages_block_shape?(method_type, block_required) &&
                  strictly_typed_params?(method_type, arg_types.size) &&
                  matches?(method_type, shared, strict: true)
              end
              return found ? [found] : NO_MATCH
            end

            overloads.select do |method_type|
              engages_block_shape?(method_type, block_required) && matches?(method_type, shared)
            end
          end

          # Whether the overload's block clause is compatible with the call site's block shape: a
          # block-bearing call engages only block-declaring overloads; a block-less call skips overloads
          # that REQUIRE one.
          def engages_block_shape?(method_type, block_required)
            return OverloadSelector.overload_has_block?(method_type) if block_required

            !OverloadSelector.overload_requires_block?(method_type)
          end

          # Treats the literal `untyped` carrier (`Dynamic[Top]`) as too imprecise to drive a strict-pass
          # match. Other `Dynamic`-wrapped types with a concrete static facet carry enough information to
          # pick a sensible overload.
          def untyped_arg?(type) = type.is_a?(Type::Dynamic) && type.static_facet.is_a?(Type::Top)

          # Issue #1021 — the strict and alias passes must not discriminate on an argument whose type
          # cannot rule an overload out: the bare untyped carrier, or a union with an untyped member. That
          # member may reach any overload at runtime, so a strict match is decided by the union's other
          # members alone — `Dynamic[top] | nil` pinned `Regexp#match?(nil) -> false` and typed a live
          # predicate as the literal `false`. The gradual pass still accepts against the whole union, so
          # `Dynamic[top] | nil` keeps both `match?` overloads and the #521 join answers `Dynamic[bool]`.
          # A `Dynamic` with a concrete static facet stays out: its facet discriminates.
          def imprecise_arg?(type)
            untyped_arg?(type) || (type.is_a?(Type::Union) && type.members.any? { |member| untyped_arg?(member) })
          end

          # Pass 1.5: for arity-compatible overloads whose every positional param is either a strict
          # nominal OR a well-known core alias (`int` / `string` / `interned` / etc.), check the arg
          # against the alias's STRICT arm. An Integer literal arg matches `int` here but not `string`, so
          # `Array#*(int)` wins over the `Array#*(string) -> String` overload — even though both translate
          # to `Dynamic[Top]` at the param level. Only fires when EVERY positional param has a known
          # alias-or-strict shape; otherwise gradual matching takes over.
          def find_matching_overload_via_aliases(overloads, arg_types:, block_required:)
            # Issue #521 — an untyped argument "maybe"-accepts EVERY alias's strict arm, so it cannot
            # discriminate between overloads here any more than in the strict pass; without this guard a
            # Dynamic arg pinned `Array#*(string) -> String` purely by declaration order.
            return nil if arg_types.any? { |t| imprecise_arg?(t) }

            overloads.find do |method_type|
              next false unless engages_block_shape?(method_type, block_required)

              fun = method_type.type
              next false unless arity_compatible?(fun, arg_types.size)

              params = positional_params_for(fun, arg_types.size)
              next false unless params.size == arg_types.size

              each_param_accepts?(params, arg_types) { |param, arg| alias_param_accepts?(param.type, arg) }
            end
          end

          # `params.zip(arg_types).all? { |param, arg| ... }` without the pair arrays: a formal beyond the
          # actuals meets `nil`, exactly as `zip` pads. Selection zips once per overload per pass, so the
          # pairs were a top allocation site of dispatch (#775). The counter is a captured local, so the
          # walk allocates nothing (a Range or an Enumerator would be one object per overload per pass).
          def each_param_accepts?(params, arg_types)
            index = -1
            params.all? { |param| yield(param, arg_types[index += 1]) }
          end

          # Checks the param's RBS type against an arg using alias-strict-arm matching. Optional / Union
          # wrappers are flattened; alias resolution is one level deep (the canonical core aliases all have
          # non-alias strict arms).
          def alias_param_accepts?(rbs_type, arg)
            nominal_names = strict_nominal_names_for(rbs_type)
            return false if nominal_names.nil? || nominal_names.empty?

            nominal_names.any? do |class_name|
              result = Type::Combinator.nominal_of(class_name).accepts(arg, mode: :gradual)
              result.yes? || result.maybe?
            end
          end

          # Returns the candidate class names a param's RBS type accepts under alias-resolved strict
          # matching, or nil when the shape cannot be reduced to a closed set of nominals (e.g. an
          # Interface or an unrecognised alias).
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

          # Returns true when every positional param the call site engages translates to a non-`Dynamic[Top]`
          # carrier. Alias / Interface / Intersection RBS types all degrade to `Dynamic[Top]` per the
          # translator's current shape — those gradually accept any arg, so an overload that includes one
          # would beat strictly-typed alternatives in pass 2 of the selector.
          def strictly_typed_params?(method_type, actual_count)
            fun = method_type.type
            # A `(?)` method type declares no params at all: it is the gradual case by construction, so it
            # must never win the strict pass over a genuinely typed sibling overload.
            return false unless fun.respond_to?(:required_positionals)
            return false unless arity_compatible?(fun, actual_count)

            params = positional_params_for(fun, actual_count)
            params.all? { |param| !alias_or_interface_param?(param.type) }
          end

          # Recursive: an Optional / Union wrapper is strict iff every member is strict. Type args of a
          # ClassInstance are NOT walked — `Range[::int]` is a Range carrier at the param level; the alias
          # only colours the element type, which is checked separately when the element is actually
          # accessed.
          #
          # `RBS::Types::Bases::Any` (the explicit `untyped` keyword) is treated like Alias / Interface /
          # Intersection — both translate to `Dynamic[Top]`, both gradually accept anything. A
          # `(untyped) -> T` catch-all overload that comes after the strictly-typed ones must lose pass 1
          # so the typed overloads win when their param actually fits the arg.
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

          # `shared` is the keyword bundle `select_candidates` assembled (see `find_matching_overload`).
          # `strict:` is `false` (gradual), `true` (strict pass) or `:proven` (pass 0; see `find_proven_overload`).
          def matches?(method_type, shared, strict: false)
            return false if method_type.respond_to?(:type_params) && rejects_keyword_required?(method_type)

            arg_types = shared[:arg_types]
            fun = method_type.type
            return false unless arity_compatible?(fun, arg_types.size)

            params = positional_params_for(fun, arg_types.size)
            each_param_accepts?(params, arg_types) { |param, arg| accepts_param?(param, arg, shared, strict) }
          end

          # Slice 4 phase 2c does not pass keyword arguments through the call site (caller passes only
          # positional `arg_types`). An overload that requires keywords is therefore not a viable
          # candidate; we skip it instead of forcing a fallback.
          def rejects_keyword_required?(method_type)
            fun = method_type.type
            return false unless fun.respond_to?(:required_keywords)

            !fun.required_keywords.empty?
          end

          # `RBS::Types::UntypedFunction` (`(?)`) declares no arity to enforce, so every call site is
          # arity-compatible with it.
          def arity_compatible?(fun, actual_count)
            return true unless fun.respond_to?(:required_positionals)

            min_arity = fun.required_positionals.size + fun.trailing_positionals.size
            return false if actual_count < min_arity

            return true if fun.rest_positionals

            max_arity = min_arity + fun.optional_positionals.size
            actual_count <= max_arity
          end

          # Builds the list of formal parameter declarations to compare against the actual arguments, in
          # positional order: required first, then as many optionals as needed, then trailing required.
          # Rest_positionals consumes the remainder; we repeat its single declaration for each absorbed
          # argument.
          def positional_params_for(fun, actual_count)
            # `(?)` declares no positional params; the caller zips this against the actual args, so an empty
            # list is what "accepts anything, constrains nothing" looks like here.
            return [] unless fun.respond_to?(:required_positionals)

            required = fun.required_positionals
            optional = fun.optional_positionals
            rest = fun.rest_positionals
            trailing = fun.trailing_positionals

            optional_needed = [actual_count - required.size - trailing.size, 0].max
            # Nothing to append: the declaration's own list is the answer, read-only (the common
            # required-positionals-only overload -- no copy, #775).
            return required if optional_needed.zero? && trailing.empty? && (rest.nil? || actual_count <= required.size)

            head = required.dup
            head.concat(optional.first(optional_needed))

            absorbed_by_rest = actual_count - head.size - trailing.size
            head.concat([rest] * absorbed_by_rest) if rest && absorbed_by_rest.positive?

            head.concat(trailing)
            head
          end

          # `shared` is the keyword bundle `select_candidates` assembled (see `find_matching_overload`).
          def accepts_param?(param, arg, shared, strict)
            param_type = shared[:param_overrides][param.name] || RbsTypeTranslator.translate(
              param.type,
              self_type: shared[:self_type],
              instance_type: shared[:instance_type],
              type_vars: shared[:type_vars],
              alias_expander: shared[:alias_expander]
            )
            # An `untyped` arg gradually accepts against every param, so a value-pinning param would be
            # "matched" with zero evidence and its value-precise return (`(nil) -> []`) would beat broader
            # overloads purely by list position. Decline the pair; only the strict pass (where the arg
            # proves the value) or the final first-overload fallback may select such an overload. (Pass 1
            # already skips untyped args entirely, so this only engages pass 2.)
            return false if untyped_arg?(arg) && value_pinning?(param_type)

            result = param_type.accepts(arg, mode: :gradual)
            return result.yes? && ProvenOverload.names_arg_class?(param_type, arg) if strict == :proven

            # A record's `maybe` for a `Hash` with a gradual arm is no evidence for the overload: with
            # `({ a: Integer }) -> Integer | (Hash[Symbol, untyped]) -> String`, `{ **o, b: 2 }` has a key the
            # closed record forbids, yet the first overload won by list position. The gradual pass still takes it.
            return false if strict && result.maybe? && Acceptance.record_against_gradual_hash?(param_type, arg)

            result.yes? || result.maybe?
          end

          # A type that admits only specific VALUES rather than a class of values: a `Constant` carrier
          # (RBS `nil` and literal types both translate to one) or a union made up entirely of them
          # (`true | false`, `1 | 2`, `nil?`-style optionals of literals).
          def value_pinning?(type)
            case type
            when Type::Constant then true
            when Type::Union then type.members.all? { |member| value_pinning?(member) }
            else false
            end
          end
        end
      end
    end
  end
end
