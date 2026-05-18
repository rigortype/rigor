# frozen_string_literal: true

require_relative "../inference/hkt_registry"
require_relative "../inference/hkt_body"

module Rigor
  module Builtins
    # ADR-20 slices 2c + 3 — Rigor-bundled Lightweight HKT
    # registrations that ship with every analyzer instance.
    # The set is intentionally small at v0.1.x: only the URIs
    # whose payoff justifies hardcoded definitions. Plugin
    # authors register more URIs through their manifests; user
    # `.rbs` overlays register through the
    # `%a{rigor:v1:hkt_register}` /
    # `%a{rigor:v1:hkt_define}` annotations Slice 1 ships.
    #
    # Today's contents:
    #
    # - `json::value[K]` — the recursive sum stdlib's
    #   `JSON.parse` returns. Body:
    #
    #     nil | true | false | Integer | Float | String
    #     | Array[App[json::value, K]]
    #     | Hash[K, App[json::value, K]]
    #
    #   The reducer handles the self-recursive `App` nodes via
    #   lazy "tying-the-knot" (see {HktReducer}). `K = String`
    #   matches stdlib's default key handling; `K = Symbol`
    #   matches `symbolize_names: true`.
    module HktBuiltins
      module_function

      # Boolean is modelled as `Constant<true> | Constant<false>`
      # at the leaf level — matches Rigor's `bool` carrier
      # spelled out (per docs/type-specification/special-types.md
      # § "bool").
      def json_value_body_tree
        body = Rigor::Inference::HktBody
        body::Union.new(arms: [
                          body::TypeLeaf.new(type: Rigor::Type::Constant.new(nil)),
                          body::TypeLeaf.new(type: Rigor::Type::Constant.new(true)),
                          body::TypeLeaf.new(type: Rigor::Type::Constant.new(false)),
                          body::TypeLeaf.new(type: Rigor::Type::Combinator.nominal_of(Integer)),
                          body::TypeLeaf.new(type: Rigor::Type::Combinator.nominal_of(Float)),
                          body::TypeLeaf.new(type: Rigor::Type::Combinator.nominal_of(String)),
                          body::NominalApp.new(
                            class_name: "Array",
                            args: [body::AppRef.new(uri: :"json::value", args: [body::Param.new(name: :K)])]
                          ),
                          body::NominalApp.new(
                            class_name: "Hash",
                            args: [
                              body::Param.new(name: :K),
                              body::AppRef.new(uri: :"json::value", args: [body::Param.new(name: :K)])
                            ]
                          )
                        ])
      end

      def json_value_registration
        Rigor::Inference::HktRegistry::Registration.new(
          uri: :"json::value",
          arity: 1,
          variance: [:out],
          bound: Rigor::Type::Combinator.untyped
        )
      end

      def json_value_definition
        Rigor::Inference::HktRegistry.definition_with_body_tree(
          uri: :"json::value",
          params: [:K],
          body_tree: json_value_body_tree,
          source_path: __FILE__,
          source_line: __LINE__ - 5
        )
      end

      # @return [Rigor::Inference::HktRegistry] frozen registry
      #   pre-seeded with all bundled HKT registrations + bodies.
      def registry
        @registry ||= Rigor::Inference::HktRegistry.new(
          registrations: [json_value_registration],
          definitions: [json_value_definition]
        ).freeze
      end

      # ADR-20 slice 3 — hardcoded `(class_name, method_name,
      # kind) => HKT application` table consulted by the
      # dispatcher's new HKT-builtin tier. Sits ABOVE
      # `RbsDispatch.try_dispatch` so a known stdlib method
      # (`JSON.parse`, `JSON.parse!`) gets the reduced HKT
      # type instead of the upstream rbs gem's `untyped`
      # return. The annotation-based `%a{rigor:v1:return:
      # App[...]}` path (parsed by
      # `RbsExtended.parse_return_type_override`) is the
      # general extension surface for user-authored sigs;
      # this table is the Rigor-bundled shortcut for the
      # handful of stdlib methods whose RBS declarations
      # cannot be cleanly overridden via RBS overlay merging.
      #
      # Each entry maps to a hash with `:uri` and `:args`
      # (an array of Ruby class names). The dispatcher
      # builds `Type::App.new(uri, args.map { Nominal })`,
      # then reduces via the env's `hkt_registry` so the
      # caller observes the unfolded form
      # (`Union[nil, true, false, ..., Array[App[json::value,
      # String]], Hash[String, App[json::value, String]]]`)
      # rather than the opaque carrier.
      JSON_VALUE_SPEC = {
        uri: :"json::value",
        args: ["String"],
        discriminator: :json_symbolize_names,
        post_reduce: nil
      }.freeze
      private_constant :JSON_VALUE_SPEC

      # YAML / Psych.safe_load reuse the json::value reducer
      # for the JSON-equivalent leaf set BUT additionally
      # honour `permitted_classes: [<Class>, ...]` literal
      # Array arguments, unioning each permitted class as an
      # extra arm of the result. Slice 2c-bis behaviour.
      YAML_SAFE_VALUE_SPEC = {
        uri: :"json::value",
        args: ["String"],
        discriminator: :json_symbolize_names,
        post_reduce: :yaml_permitted_classes
      }.freeze
      private_constant :YAML_SAFE_VALUE_SPEC

      METHOD_RETURN_OVERRIDES = {
        # JSON — stdlib's `json` library. Upstream rbs declares
        # `(string, ?options) -> untyped`; the HKT-builtin tier
        # tightens to the recursive `json::value[K]` union.
        ["JSON", :parse,  :singleton] => JSON_VALUE_SPEC,
        ["JSON", :parse!, :singleton] => JSON_VALUE_SPEC,
        ["JSON", :load,   :singleton] => JSON_VALUE_SPEC,
        # YAML.safe_load / Psych.safe_load — default
        # `permitted_classes: []` admits exactly the JSON
        # vocabulary (nil / true / false / Integer / Float /
        # String / Array / Hash), so the json::value tree
        # also describes them. When the call passes a literal
        # `permitted_classes: [Date, Symbol, ...]` Array, the
        # `:yaml_permitted_classes` post_reduce unions each
        # named class into the result. Non-literal options
        # (a variable, a constant reference, a `+ classes`
        # concat) silently no-op and the caller observes the
        # base json::value envelope only. YAML.load /
        # YAML.unsafe_load deliberately stay out of the
        # override table — they can return ANY Ruby object
        # and have no useful HKT envelope.
        ["YAML",  :safe_load,      :singleton] => YAML_SAFE_VALUE_SPEC,
        ["YAML",  :safe_load_file, :singleton] => YAML_SAFE_VALUE_SPEC,
        ["Psych", :safe_load,      :singleton] => YAML_SAFE_VALUE_SPEC,
        ["Psych", :safe_load_file, :singleton] => YAML_SAFE_VALUE_SPEC
      }.freeze

      # @return [Rigor::Type, nil] the reduced HKT type for
      #   the given (class_name, method_name, kind) triple,
      #   or `nil` when no built-in override is registered.
      #   When `arg_types` is supplied AND the entry carries a
      #   `:discriminator` symbol, the discriminator may swap
      #   the spec's default args for an alternate (e.g.
      #   `JSON.parse(str, symbolize_names: true)` discriminates
      #   `K = Symbol` instead of the default `K = String`).
      def method_return_override(class_name:, method_name:, kind:, arg_types: nil, hkt_registry: nil)
        spec = METHOD_RETURN_OVERRIDES[[class_name, method_name.to_sym, kind]]
        return nil unless spec

        args = discriminated_args(spec, arg_types)
        registration = hkt_registry&.registration(spec[:uri])
        bound = registration&.bound || Rigor::Type::Combinator.untyped
        app = Rigor::Type::App.new(spec[:uri], args, bound: bound)

        reduced =
          if hkt_registry.nil? || !hkt_registry.defined?(spec[:uri])
            app
          else
            hkt_registry.reduce(app) || app
          end

        apply_post_reduce(spec[:post_reduce], reduced, arg_types)
      end

      # Per-spec discriminator dispatch. Slice 3 ships one
      # built-in discriminator (`json_symbolize_names`) that
      # observes the optional 2nd argument's `HashShape` for a
      # literal `symbolize_names: true` entry. Plugin / Rigor-
      # bundled callers wanting their own discriminators add a
      # branch here.
      def discriminated_args(spec, arg_types)
        default_args = spec[:args].map { |n| Rigor::Type::Nominal.new(n) }
        return default_args if arg_types.nil?
        return default_args unless spec[:discriminator] == :json_symbolize_names
        return default_args unless json_symbolize_names?(arg_types)

        [Rigor::Type::Nominal.new("Symbol")]
      end

      # Returns true iff the call-site's 2nd argument is a
      # `Type::HashShape` carrying a literal
      # `symbolize_names: true` entry. Anything else
      # (no second arg, non-HashShape, missing key, non-literal
      # `true`) returns false so the default `K = String`
      # branch wins.
      def json_symbolize_names?(arg_types)
        return false unless arg_types.is_a?(Array) && arg_types.size >= 2

        opts = arg_types[1]
        return false unless opts.is_a?(Rigor::Type::HashShape)

        value = opts.pairs[:symbolize_names] || opts.pairs["symbolize_names"]
        value.is_a?(Rigor::Type::Constant) && value.value == true
      end

      # Slice 2c-bis — post-reduce hook. Receives the already-
      # reduced `Type` and the call-site's `arg_types`; returns
      # a (possibly augmented) `Type`. `kind = nil` is the
      # identity (passes the reduced type through unchanged).
      # Only `:yaml_permitted_classes` is implemented today;
      # plugin / Rigor-bundled callers wanting their own
      # post-reduce hooks add a branch here.
      def apply_post_reduce(kind, reduced, arg_types)
        case kind
        when :yaml_permitted_classes
          augment_with_yaml_permitted_classes(reduced, arg_types)
        else
          # `nil` (no post-reduce declared) and any future
          # unrecognised kind both pass the reduced type
          # through unchanged. Unknown kinds are silently
          # tolerated rather than raised because adding a
          # new kind on a Rigor upgrade should not crash a
          # stale METHOD_RETURN_OVERRIDES entry on the
          # caller side.
          reduced
        end
      end

      # Inspects arg_types for a `permitted_classes: [<Class>,
      # ...]` literal Array in the options Hash and unions
      # each named class into the reduced result. Non-literal
      # `permitted_classes:` values (a variable, a constant
      # reference, a concat) silently no-op and the caller
      # observes the base json::value envelope only. Defensive
      # against the various ways Ruby literal arrays surface
      # as Rigor types: `Tuple[Singleton<Date>]` for a single
      # element, `Tuple[Singleton<Date>, Singleton<Symbol>]`
      # for multiple, `Nominal[Array, [Singleton<...>]]` if
      # the analyzer widened (rare for literal arrays).
      def augment_with_yaml_permitted_classes(reduced, arg_types)
        return reduced unless arg_types.is_a?(Array) && arg_types.size >= 2

        opts = arg_types[1]
        return reduced unless opts.is_a?(Rigor::Type::HashShape)

        value = opts.pairs[:permitted_classes] || opts.pairs["permitted_classes"]
        return reduced if value.nil?

        extras = permitted_class_nominals(value)
        return reduced if extras.empty?

        Rigor::Type::Combinator.union(reduced, *extras)
      end

      # Extract Singleton-class elements from a Tuple or
      # Array-shape carrier, mapping each to its Nominal
      # counterpart. Returns an empty array when no static
      # Singletons are reachable (e.g. value is `Dynamic[T]`,
      # element types are non-Singleton, etc.).
      def permitted_class_nominals(value)
        candidates =
          if value.is_a?(Rigor::Type::Tuple)
            value.elements
          elsif value.is_a?(Rigor::Type::Nominal) && value.class_name == "Array" && value.type_args.size == 1
            element = value.type_args.first
            element.is_a?(Rigor::Type::Union) ? element.members : [element]
          else
            []
          end

        candidates.filter_map do |c|
          c.is_a?(Rigor::Type::Singleton) ? Rigor::Type::Nominal.new(c.class_name) : nil
        end
      end
    end
  end
end
