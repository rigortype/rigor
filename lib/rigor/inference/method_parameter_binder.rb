# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../type"
require_relative "../rbs_extended"
require_relative "rbs_type_translator"

module Rigor
  module Inference
    # Builds the entry scope of a method body by translating the method's
    # parameter list into a `name -> Rigor::Type` map.
    #
    # Parameter types come from the surrounding class's RBS signature
    # when one is available; otherwise every parameter defaults to
    # `Dynamic[Top]`. The default is the Slice 1 fail-soft answer for
    # unknown values, so a method whose RBS signature is missing or
    # whose parameters cannot be matched still binds every name into
    # the scope (a method body whose `Local x` reads return
    # `Dynamic[Top]` instead of falling through to the unbound-local
    # `Dynamic[Top]` event is the same observable type, but the
    # binding presence is what later slices need to attach narrowing
    # facts to).
    #
    # The class context (`class_path:`) and `singleton:` flag are
    # supplied by the caller (the StatementEvaluator) which threads
    # them as the lexical class scope. The binder makes no assumption
    # about how that context was computed; it only uses it to build
    # the `(class_name, method_name)` lookup key for
    # `Rigor::Environment::RbsLoader#instance_method` /
    # `#singleton_method`.
    #
    # See docs/internal-spec/inference-engine.md for the binding contract.
    # rubocop:disable Metrics/ClassLength
    class MethodParameterBinder
      # @param environment [Rigor::Environment]
      # @param class_path [String, nil] the qualified name of the class
      #   the method is defined in (e.g., `"Foo::Bar"`), or `nil` for a
      #   top-level `def` outside any class. When `nil` (or when the
      #   class is unknown to RBS), every parameter falls back to
      #   `Dynamic[Top]`.
      # @param singleton [Boolean] `true` when the def is a singleton
      #   method (either `def self.foo` or a `def foo` inside
      #   `class << self`); routes the lookup through
      #   `RbsLoader#singleton_method`.
      def initialize(environment:, class_path:, singleton:)
        @environment = environment
        @class_path = class_path
        @singleton = singleton
      end

      # @param def_node [Prism::DefNode]
      # @return [Hash{Symbol => Rigor::Type}] ordered map from parameter
      #   name to bound type. Anonymous parameters (`*` and `**` without
      #   a name) are skipped.
      def bind(def_node)
        slots = collect_slots(def_node.parameters)
        types = default_types_for(slots)

        rbs_method = lookup_rbs_method(def_node)
        return types unless rbs_method

        apply_rbs_overloads(types, slots, rbs_method.method_types) unless rbs_method.method_types.empty?
        # `rigor:v1:param: <name> <refinement>` annotations
        # tighten the bound type for matching slots. Applied
        # after the RBS-overload pass so the override is the
        # authoritative answer regardless of what the RBS
        # signature declared.
        apply_param_overrides(types, slots, rbs_method)
        types
      end

      private

      ParamSlot = Data.define(:kind, :name, :index)
      private_constant :ParamSlot

      # Walk the Prism `ParametersNode` and emit one slot per named
      # parameter, in declaration order. Anonymous slots (rest /
      # keyword-rest with no name) are skipped because we have no
      # local name to bind. The slot's `:index` is the positional
      # index for required/optional/trailing positionals (used to look
      # up the matching RBS function param) and is `nil` for the
      # singleton kinds (`:rest_positional`, `:rest_keyword`,
      # `:block`).
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
        params_node.requireds.each_with_index { |p, i| slots << ParamSlot.new(:required_positional, p.name, i) }
        params_node.optionals.each_with_index { |p, i| slots << ParamSlot.new(:optional_positional, p.name, i) }
        rest = params_node.rest
        slots << ParamSlot.new(:rest_positional, rest.name, nil) if rest.respond_to?(:name) && rest&.name
        params_node.posts.each_with_index { |p, i| slots << ParamSlot.new(:trailing_positional, p.name, i) }
        slots
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
        # `def self.foo` always means a singleton method on the
        # immediate enclosing class. `def foo` inside `class << self`
        # is also a singleton method (the StatementEvaluator threads
        # the `singleton:` flag through this case).
        if def_node.receiver.is_a?(Prism::SelfNode) || @singleton
          Rigor::Reflection.singleton_method_definition(@class_path, method_name, environment: @environment)
        else
          Rigor::Reflection.instance_method_definition(@class_path, method_name, environment: @environment)
        end
      end

      # Bind each parameter slot to the union of the matching parameter
      # types across every overload that *has* that slot. Overloads
      # that omit the slot (e.g., `Array#first` has both `()` and
      # `(int)` overloads — only the second matches a `def first(n)`
      # redefinition) are silently skipped, so the binder defaults to
      # the most informative type the RBS signature provides without
      # having to know which overload the runtime will pick.
      def apply_rbs_overloads(types, slots, method_types)
        slots.each do |slot|
          next if slot.name.nil?

          translated = collect_translated_types(method_types, slot)
          next if translated.empty?

          types[slot.name] = build_slot_type(translated, slot.kind)
        end
      end

      # Reads the override map off the method's annotations and
      # replaces the binding for any slot whose name appears in
      # the map. Anonymous slots are skipped (no name to match).
      # The override is used verbatim — no `:rest_*` re-wrapping —
      # so authors who tighten a `*rest` parameter to e.g.
      # `non-empty-array[Integer]` describe the parameter binding
      # they actually want, not its element type.
      def apply_param_overrides(types, slots, rbs_method)
        override_map = RbsExtended.param_type_override_map(rbs_method)
        return if override_map.empty?

        slots.each do |slot|
          next if slot.name.nil?

          override = override_map[slot.name]
          next if override.nil?

          types[slot.name] = override
        end
      end

      def collect_translated_types(method_types, slot)
        rbs_types = method_types.flat_map do |mt|
          t = rbs_type_for_slot(mt.type, slot)
          t ? [t] : []
        end
        rbs_types.map { |t| translate_with_self(t) }.uniq
      end

      def build_slot_type(translated, kind)
        bound = translated.size == 1 ? translated.first : Type::Combinator.union(*translated)
        wrap_for_kind(bound, kind)
      end

      # Dispatch table from slot kind to a small lambda that pulls the
      # matching RBS parameter type out of an `RBS::Types::Function`.
      # The hash keeps `rbs_type_for_slot` linear (one lookup, one
      # call) so the cyclomatic-complexity budget does not balloon as
      # future slices add more parameter kinds (e.g., `**Symbol kw` is
      # a candidate for a stricter route in Slice 5+).
      # Match keyword parameters by name across both required and
      # optional keyword maps. RBS may declare a keyword as optional
      # (`?by:`) while the Ruby `def` lists it as required (or vice
      # versa); the binding is by-name regardless of which side
      # defines it.
      KEYWORD_PROVIDER = lambda do |fn, slot|
        fn.required_keywords[slot.name]&.type || fn.optional_keywords[slot.name]&.type
      end
      private_constant :KEYWORD_PROVIDER

      RBS_TYPE_PROVIDERS = {
        required_positional: ->(fn, slot) { fn.required_positionals[slot.index]&.type },
        optional_positional: ->(fn, slot) { fn.optional_positionals[slot.index]&.type },
        rest_positional: ->(fn, _slot) { fn.rest_positionals&.type },
        trailing_positional: ->(fn, slot) { fn.trailing_positionals[slot.index]&.type },
        required_keyword: KEYWORD_PROVIDER,
        optional_keyword: KEYWORD_PROVIDER,
        rest_keyword: ->(fn, _slot) { fn.rest_keywords&.type }
      }.freeze
      private_constant :RBS_TYPE_PROVIDERS

      def rbs_type_for_slot(function, slot)
        provider = RBS_TYPE_PROVIDERS[slot.kind]
        return nil unless provider

        provider.call(function, slot)
      end

      # The variable bound to a `*rest` parameter is the *Array* of
      # rest-positional arguments, not a single element. Likewise
      # `**kw` is bound to a `Hash[Symbol, V]`. Wrap the translated
      # element/value type accordingly so `rest` reads as
      # `Array[Integer]` rather than `Integer`.
      def wrap_for_kind(translated, kind)
        case kind
        when :rest_positional
          Type::Combinator.nominal_of("Array", type_args: [translated])
        when :rest_keyword
          symbol_nominal = Type::Combinator.nominal_of("Symbol")
          Type::Combinator.nominal_of("Hash", type_args: [symbol_nominal, translated])
        else
          translated
        end
      end

      def translate_with_self(rbs_type)
        self_type, instance_type = self_and_instance_type
        RbsTypeTranslator.translate(
          rbs_type,
          self_type: self_type,
          instance_type: instance_type
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
    # rubocop:enable Metrics/ClassLength
  end
end
