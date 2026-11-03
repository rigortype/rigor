# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../type"
require_relative "../rbs_extended"
require_relative "rbs_type_translator"

module Rigor
  module Inference
    # Builds the entry scope of a method body by translating the method's parameter list into a
    # `name -> Rigor::Type` map.
    #
    # Parameter types come from the surrounding class's RBS signature when one is available;
    # otherwise every parameter defaults to `Dynamic[Top]`. The default is the Slice 1 fail-soft
    # answer for unknown values, so a method whose RBS signature is missing or whose parameters
    # cannot be matched still binds every name into the scope (a method body whose `Local x`
    # reads return `Dynamic[Top]` instead of falling through to the unbound-local
    # `Dynamic[Top]` event is the same observable type, but the binding presence is what later
    # slices need to attach narrowing facts to).
    #
    # The class context (`class_path:`) and `singleton:` flag are supplied by the caller (the
    # StatementEvaluator) which threads them as the lexical class scope. The binder makes no
    # assumption about how that context was computed; it only uses it to build the
    # `(class_name, method_name)` lookup key for `Rigor::Environment::RbsLoader#instance_method`
    # / `#singleton_method`.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract.
    # Leaf-name extraction for a destructured positional parameter (`Prism::MultiTargetNode`).
    # Stateless; lifted out of {MethodParameterBinder} so the binder's class length stays in
    # budget.
    module Destructure
      module_function

      # Collect every leaf local name a `MultiTargetNode` binds, recursing through nested
      # destructures (`((a, b), c)`) and the splat slot (`(a, *rest)`). Targets without a
      # `#name` (an index/call write target, vanishingly rare in a parameter position) are
      # skipped — there is no local to bind.
      def target_names(multi_target)
        entries = multi_target.lefts + [multi_target.rest, *multi_target.rights].compact
        entries.flat_map { |entry| names_for_entry(entry) }
      end

      def names_for_entry(entry)
        # A splat sub-target (`*rest` inside the destructure) wraps its real target in a
        # `SplatNode#expression`; unwrap it.
        entry = entry.expression if entry.is_a?(Prism::SplatNode) && entry.expression
        return [] if entry.nil?
        return target_names(entry) if entry.is_a?(Prism::MultiTargetNode)
        return [entry.name] if entry.respond_to?(:name) && entry.name

        []
      end
    end

    # Issue #2681 — which declared type, if any, one RBS overload hands a `def`'s parameter slot when the def's shape
    # need not match the declaration's (an override bound from its ancestor, or a source `def` whose RBS was written
    # for another shape). A slot takes a type only where the two shapes line up:
    #
    # - a leading positional (required or optional) takes the declared leading positional at the same ABSOLUTE
    #   position, and a post positional the declared trailing one, provided both sides have as many post as
    #   trailing positionals: Ruby fills the leading parameters left to right on both sides, so the argument a call
    #   puts at a leading position reaches the slot at the same one;
    # - `*rest` takes the declared rest only when the def has exactly the declared leading positionals;
    # - a keyword takes the declared keyword of its name, and `**kw` the declared keyword rest only when the def
    #   names every declared keyword.
    #
    # Any other overlap is {MISALIGNED}, and leaves the slot `Dynamic[Top]`. {NOT_PASSED} is an overload that passes
    # the slot nothing (`def first(n)` under `Array#first`'s `()`), which the binder skips.
    module SlotAlignment
      module_function

      MISALIGNED = :misaligned
      NOT_PASSED = :not_passed

      Shape = Data.define(:requireds, :leading, :posts, :keywords)

      def shape_of(params_node)
        return Shape.new(0, 0, 0, [].freeze) if params_node.nil?

        requireds = params_node.requireds.size
        keywords = params_node.keywords.map(&:name).freeze
        Shape.new(requireds, requireds + params_node.optionals.size, params_node.posts.size, keywords)
      end

      # The RBS type the overload `function` declares for `slot`, {MISALIGNED} or {NOT_PASSED}.
      def declared(function, slot, shape)
        case slot.kind
        when :required_positional then leading(function, shape, slot.index)
        when :optional_positional then leading(function, shape, shape.requireds + slot.index)
        when :trailing_positional then trailing(function, shape, slot.index)
        when :rest_positional then rest(function, shape)
        when :required_keyword, :optional_keyword then keyword(function, slot.name)
        when :rest_keyword then rest_keyword(function, shape)
        else NOT_PASSED
        end
      end

      def leading(function, shape, position)
        return MISALIGNED unless function.trailing_positionals.size == shape.posts

        required = function.required_positionals
        return required[position].type if position < required.size

        optional = function.optional_positionals[position - required.size]
        return optional.type if optional

        function.rest_positionals ? MISALIGNED : NOT_PASSED
      end

      def trailing(function, shape, index)
        return MISALIGNED unless function.trailing_positionals.size == shape.posts

        function.trailing_positionals[index].type
      end

      def rest(function, shape)
        return MISALIGNED unless function.trailing_positionals.size == shape.posts

        declared_leading = function.required_positionals.size + function.optional_positionals.size
        return MISALIGNED if shape.leading < declared_leading
        return NOT_PASSED if function.rest_positionals.nil?

        shape.leading == declared_leading ? function.rest_positionals.type : MISALIGNED
      end

      def keyword(function, name)
        declared = function.required_keywords[name] || function.optional_keywords[name]
        return declared.type if declared

        function.rest_keywords ? MISALIGNED : NOT_PASSED
      end

      def rest_keyword(function, shape)
        declared = function.required_keywords.keys + function.optional_keywords.keys
        return MISALIGNED unless declared.all? { |name| shape.keywords.include?(name) }

        function.rest_keywords ? function.rest_keywords.type : NOT_PASSED
      end
    end

    class MethodParameterBinder
      # @param class_path — the qualified name of the class the method is defined in
      #   (e.g., `"Foo::Bar"`), or `nil` for a top-level `def` outside any class. When `nil` (or
      #   when the class is unknown to RBS), every parameter falls back to `Dynamic[Top]`.
      # @param singleton — `true` when the def is a singleton method (either `def
      #   self.foo` or a `def foo` inside `class << self`); routes the lookup through
      #   `RbsLoader#singleton_method`.
      # @param source_path — the project-relative path of the file the method is
      #   defined in. Used to match ADR-28 path-scoped protocol contracts; `nil` (the default
      #   for synthetic / probe scopes) disables the contract tier.
      # @param scope — the scope the `def` is written in. When supplied, a `def` on a Ruby-source class with no RBS
      #   of its own binds the parameters of the declaration it overrides on an ADR-43 allow-listed ancestor (#2681);
      #   `nil` keeps that class's parameters `Dynamic[Top]`.
      def initialize(environment:, class_path:, singleton:, source_path: nil, scope: nil)
        @environment = environment
        @class_path = class_path
        @singleton = singleton
        @source_path = source_path
        @scope = scope
      end

      # @return ordered map from parameter name to bound type.
      #   Anonymous parameters (`*` and `**` without a name) are skipped.
      def bind(def_node)
        slots = collect_slots(def_node.parameters)
        types = default_types_for(slots)

        rbs_method = lookup_rbs_method(def_node)
        if rbs_method
          unless rbs_method.method_types.empty?
            apply_rbs_overloads(types, slots, rbs_method.method_types, SlotAlignment.shape_of(def_node.parameters))
          end
          # `rigor:v1:param: <name> <refinement>` annotations tighten the bound type for matching
          # slots. Applied after the RBS-overload pass so the override is the authoritative
          # answer regardless of what the RBS signature declared.
          apply_param_overrides(types, slots, rbs_method)
        end
        # ADR-28 — a path-scoped protocol contract supplies the parameter type for a matching
        # `def`. Applied last (most authoritative) and regardless of RBS presence: the methods a
        # contract targets — controller actions and the like — typically have no RBS signature
        # at all, so this tier must run even when `rbs_method` is nil.
        apply_protocol_contract(types, slots, def_node)
        types
      end

      private

      ParamSlot = Data.define(:kind, :name, :index)
      private_constant :ParamSlot

      # Slot kinds a contract's positional `index` can address.
      POSITIONAL_KINDS = %i[required_positional optional_positional].freeze
      private_constant :POSITIONAL_KINDS

      # Walk the Prism `ParametersNode` and emit one slot per named parameter, in declaration
      # order. Anonymous slots (rest / keyword-rest with no name) are skipped because we have no
      # local name to bind. The slot's `:index` is the positional index for
      # required/optional/trailing positionals (used to look up the matching RBS function param)
      # and is `nil` for the singleton kinds (`:rest_positional`, `:rest_keyword`, `:block`).
      def collect_slots(params_node)
        return [] if params_node.nil?

        slots = []
        slots.concat(positional_slots(params_node))
        slots.concat(keyword_slots(params_node))
        append_rest_keyword_slot(slots, params_node)
        append_block_slot(slots, params_node)
        slots
      end

      def positional_slots(params_node)
        slots = []
        params_node.requireds.each_with_index do |p, i|
          append_positional_slot(slots, :required_positional, p, i)
        end
        params_node.optionals.each_with_index { |p, i| slots << ParamSlot.new(:optional_positional, p.name, i) }
        rest = params_node.rest
        slots << ParamSlot.new(:rest_positional, rest.name, nil) if rest.respond_to?(:name) && rest&.name
        params_node.posts.each_with_index do |p, i|
          append_positional_slot(slots, :trailing_positional, p, i)
        end
        slots
      end

      # A destructured positional parameter — `def f((a, b))` — is a `Prism::MultiTargetNode` in
      # the `requireds`/`posts` list, not a `RequiredParameterNode`, so it has no `#name`. Bind
      # each leaf sub-target local to `Dynamic[Top]` (a `:destructured_positional` slot with no
      # RBS index) instead of crashing on a blind `.name`. Binding the names at all is what
      # matters: it keeps the destructured locals present in the entry scope so the body's reads
      # of them don't fall through to undefined-local noise. The element types are not cheaply
      # available from the parameter list alone (no RBS function param maps onto a destructured
      # slot), so `Dynamic[Top]` is the sound default.
      def append_positional_slot(slots, kind, param, index)
        if param.is_a?(Prism::MultiTargetNode)
          Destructure.target_names(param).each do |name|
            slots << ParamSlot.new(:destructured_positional, name, nil)
          end
        else
          slots << ParamSlot.new(kind, param.name, index)
        end
      end

      def keyword_slots(params_node)
        params_node.keywords.filter_map do |kw|
          case kw
          when Prism::RequiredKeywordParameterNode
            ParamSlot.new(:required_keyword, kw.name, kw.name)
          when Prism::OptionalKeywordParameterNode
            ParamSlot.new(:optional_keyword, kw.name, kw.name)
          end
        end
      end

      def append_rest_keyword_slot(slots, params_node)
        kw_rest = params_node.keyword_rest
        return unless kw_rest.respond_to?(:name) && kw_rest&.name

        slots << ParamSlot.new(:rest_keyword, kw_rest.name, nil)
      end

      def append_block_slot(slots, params_node)
        block = params_node.block
        return unless block.respond_to?(:name) && block&.name

        slots << ParamSlot.new(:block, block.name, nil)
      end

      def default_types_for(slots)
        slots.to_h { |slot| [slot.name, Type::Combinator.untyped] }
      end

      def lookup_rbs_method(def_node)
        return nil if @class_path.nil?

        method_name = def_node.name
        # `def self.foo` always means a singleton method on the immediate enclosing class. `def
        # foo` inside `class << self` is also a singleton method (the StatementEvaluator threads
        # the `singleton:` flag through this case).
        # ADR-43 (#2681) — a source-only subclass of an allow-listed RBS-complete ancestor (`Rigor::Plugin::Base`)
        # overriding one of its hooks binds the hook's declared parameters, as an empty RBS declaration of the
        # subclass would through RBS's own inheritance.
        kind = def_node.receiver.is_a?(Prism::SelfNode) || @singleton ? :singleton : :instance
        MethodDispatcher::RbsDispatch.def_declaration(@environment, @class_path, kind, method_name, @scope)
      end

      # Bind each parameter slot to the union of the matching parameter types across every
      # overload that *has* that slot, where the def's parameter shape lines up with the overload's
      # ({SlotAlignment}); one overload that does not line up leaves the slot `Dynamic[Top]`.
      # Overloads that pass the slot no argument (e.g., `Array#first` has
      # both `()` and `(int)` overloads — only the second matches a `def first(n)` redefinition)
      # are silently skipped, so the binder defaults to the most informative type the RBS
      # signature provides without having to know which overload the runtime will pick.
      #
      # An overload declared `(?)` (`RBS::Types::UntypedFunction`, issue #1430) has no parameter lists and
      # accepts any argument in every slot, so no slot can be narrowed below `Dynamic[Top]`: binding a typed
      # sibling overload's parameter type would read a value that overload legitimately passes as a
      # contradiction inside the body. Every slot keeps its default; the declared return type still applies.
      def apply_rbs_overloads(types, slots, method_types, shape)
        return unless method_types.all? { |mt| mt.type.respond_to?(:required_positionals) }

        slots.each do |slot|
          next if slot.name.nil?

          translated = collect_translated_types(method_types, slot, shape)
          next if translated.nil? || translated.empty?

          types[slot.name] = build_slot_type(translated, slot.kind)
        end
      end

      # Reads the override map off the method's annotations and replaces the binding for any
      # slot whose name appears in the map. Anonymous slots are skipped (no name to match). The
      # override is used verbatim — no `:rest_*` re-wrapping — so authors who tighten a `*rest`
      # parameter to e.g. `non-empty-array[Integer]` describe the parameter binding they
      # actually want, not its element type.
      def apply_param_overrides(types, slots, rbs_method)
        override_map = RbsExtended.param_type_override_map(rbs_method, environment: @environment)
        return if override_map.empty?

        slots.each do |slot|
          next if slot.name.nil?

          override = override_map[slot.name]
          next if override.nil?

          types[slot.name] = override
        end
      end

      # ADR-28 — when a path-scoped protocol contract targets this `def` (file path matches the
      # contract's `path_glob`, method name + singleton-ness match), replace each contracted
      # positional slot's binding with the contract's declared type. The type name resolves
      # against the environment lazily here; an unresolvable name (the protocol's RBS not
      # loaded) falls through to whatever the prior tiers bound, fail-soft.
      def apply_protocol_contract(types, slots, def_node)
        return if @source_path.nil?

        registry = @environment.respond_to?(:plugin_registry) ? @environment.plugin_registry : nil
        return if registry.nil?

        contract = matching_contract(registry, def_node)
        return if contract.nil?

        contract.param_types.each do |param_type|
          slot = positional_slot_at(slots, param_type.index)
          next if slot.nil? || slot.name.nil?

          resolved = @environment.nominal_for_name(param_type.type_name)
          next if resolved.nil?

          types[slot.name] = resolved
        end
      end

      def matching_contract(registry, def_node)
        contracts = registry.contracts_for_path(@source_path)
        return nil if contracts.empty?

        singleton = def_node.receiver.is_a?(Prism::SelfNode) || @singleton
        contracts.find { |contract| contract.method_name == def_node.name && contract.singleton == singleton }
      end

      def positional_slot_at(slots, index)
        slots.find { |slot| POSITIONAL_KINDS.include?(slot.kind) && slot.index == index }
      end

      # The translated types the overloads declare for `slot`, or nil when one of them does not line up with the
      # def's parameter shape ({SlotAlignment}): that overload may hand the slot an argument of another type.
      def collect_translated_types(method_types, slot, shape)
        rbs_types = []
        method_types.each do |mt|
          declared = SlotAlignment.declared(mt.type, slot, shape)
          return nil if declared.equal?(SlotAlignment::MISALIGNED)

          rbs_types << declared unless declared.equal?(SlotAlignment::NOT_PASSED)
        end
        rbs_types.map { |t| translate_with_self(t) }.uniq
      end

      def build_slot_type(translated, kind)
        bound = translated.size == 1 ? translated.first : Type::Combinator.union(*translated)
        wrap_for_kind(bound, kind)
      end

      # The variable bound to a `*rest` parameter is the *Array* of rest-positional arguments,
      # not a single element. Likewise `**kw` is bound to a `Hash[Symbol, V]`. Wrap the
      # translated element/value type accordingly so `rest` reads as `Array[Integer]` rather
      # than `Integer`.
      def wrap_for_kind(translated, kind)
        case kind
        when :rest_positional
          Type::Combinator.nominal_of("Array", type_args: [translated])
        when :rest_keyword
          Type::Combinator.nominal_of("Hash", type_args: [Type::Combinator.nominal_of("Symbol"), translated])
        else
          translated
        end
      end

      def translate_with_self(rbs_type)
        self_type, instance_type = self_and_instance_type
        RbsTypeTranslator.translate(
          rbs_type,
          self_type: self_type,
          instance_type: instance_type,
          alias_expander: @environment&.rbs_loader
        )
      rescue StandardError
        Type::Combinator.untyped
      end

      def self_and_instance_type
        return [nil, nil] if @class_path.nil?

        instance = @environment.nominal_for_name(@class_path)
        if @singleton
          singleton = @environment.singleton_for_name(@class_path)
          [singleton, instance]
        else
          [instance, instance]
        end
      end
    end
  end
end
