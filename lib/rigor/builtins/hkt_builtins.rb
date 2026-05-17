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
      METHOD_RETURN_OVERRIDES = {
        ["JSON", :parse,  :singleton] => { uri: :"json::value", args: ["String"] },
        ["JSON", :parse!, :singleton] => { uri: :"json::value", args: ["String"] },
        ["JSON", :load,   :singleton] => { uri: :"json::value", args: ["String"] }
      }.freeze

      # @return [Rigor::Type, nil] the reduced HKT type for
      #   the given (class_name, method_name, kind) triple,
      #   or `nil` when no built-in override is registered.
      def method_return_override(class_name:, method_name:, kind:, hkt_registry: nil)
        spec = METHOD_RETURN_OVERRIDES[[class_name, method_name.to_sym, kind]]
        return nil unless spec

        args = spec[:args].map { |n| Rigor::Type::Nominal.new(n) }
        registration = hkt_registry&.registration(spec[:uri])
        bound = registration&.bound || Rigor::Type::Combinator.untyped
        app = Rigor::Type::App.new(spec[:uri], args, bound: bound)

        return app if hkt_registry.nil? || !hkt_registry.defined?(spec[:uri])

        hkt_registry.reduce(app) || app
      end
    end
  end
end
