# frozen_string_literal: true

require "rigor/plugin"
require_relative "ffi/binding_recognizer"
require_relative "ffi/types"
require_relative "ffi/target_detector"
require_relative "ffi/analyzer"
require_relative "ffi/catalog"
require_relative "ffi/discoverer"

module Rigor
  module Plugin
    class FFI < Base
      manifest(
        id: "ffi",
        # Bumped 2026-09-10 (#918) — declares `config_schema` for the two `.rigor.yml` surfaces ADR-30
        # WD4 (`exceptions`) and WD6 (`target`) already read off `config` but the manifest never
        # published, so both keys were rejected by `Manifest#validate_config` as unknown.
        version: "0.2.0",
        description: "Models FFI library bindings, struct layouts, callbacks, carrier types, and ffx target compatibility.",
        signature_paths: ["sig"],
        config_schema: {
          # WD4 — typedef alias names the nominal-opaque-pointer heuristic should treat as a transparent
          # `:pointer` alias even though they match the `_ptr$` / `_handle$` naming pattern.
          "exceptions" => { kind: :array, default: [] },
          # WD6 — forces ffx-target detection instead of the `extconf.rb` / `Gemfile.lock` cascade.
          # `"auto"` (the default) keeps the cascade; `"ffi"` / `"ffx"` pin the target outright.
          "target" => { kind: :string, default: "auto" }
        }
      )

      producer :ffi_catalog do
        root = config["root"] || Dir.pwd
        Discoverer.discover(root: root)
      end

      # Dynamic return rule for attached FFI functions
      # Gated on known FFI library receivers and attached function names
      #
      # Issue #701 — both receiver kinds are declared because the block below already resolved
      # `Nominal` and `Singleton` alike: `attach_function` installs the binding on the library module
      # itself (`MyLib.strlen`) and `include`ing that module makes the same name an instance call, so
      # neither kind is an accident. The kind-aware gate makes that intent explicit rather than relying
      # on a `receivers:` entry answering for both.
      dynamic_return receivers: -> { both_receiver_kinds(producer_value(:ffi_catalog)&.libraries) },
                     methods: -> { producer_value(:ffi_catalog)&.function_method_names || [] } do |call_node, scope|
        catalog = producer_value(:ffi_catalog)
        next nil if catalog.nil?

        receiver_type = call_node.receiver ? scope&.type_of(call_node.receiver) : scope&.self_type
        receiver_class = case receiver_type
                         when Rigor::Type::Nominal, Rigor::Type::Singleton then receiver_type.class_name
                         end
        next nil if receiver_class.nil?

        fact = catalog.function_for(receiver_class, call_node.name)
        next nil if fact.nil?

        Types.return_type_for(
          fact.return_type,
          target: @target || :ffi,
          module_name: fact.receiver_name,
          exceptions: @exceptions || [],
          typedefs: catalog.typedefs,
          callbacks: catalog.callbacks
        )
      end

      # Dynamic return rule for FFI struct field accessors
      # Gated on known FFI struct class names and field names
      #
      # Issue #701 — both kinds again, for the same reason: the block resolves the receiver itself and
      # answers only for a name the discovered layout carries, so restricting the gate to instances
      # would narrow a shipped rule on a shape nothing in the corpus has adjudicated.
      dynamic_return receivers: -> { both_receiver_kinds(producer_value(:ffi_catalog)&.struct_names) },
                     methods: -> { producer_value(:ffi_catalog)&.struct_field_names || [] } do |call_node, scope|
        catalog = producer_value(:ffi_catalog)
        next nil if catalog.nil?

        receiver_type = call_node.receiver ? scope&.type_of(call_node.receiver) : scope&.self_type
        receiver_class = case receiver_type
                         when Rigor::Type::Nominal, Rigor::Type::Singleton then receiver_type.class_name
                         end
        next nil if receiver_class.nil?

        fields = catalog.struct_fields(receiver_class)
        next nil if fields.nil?

        if call_node.name == :[]
          arg = call_node.arguments&.arguments&.first
          field_sym = Analyzer.extract_symbol(arg)
          field_type = fields[field_sym]
          next nil if field_type.nil?

          Types.return_type_for(
            field_type,
            target: @target || :ffi,
            module_name: receiver_class,
            exceptions: @exceptions || [],
            typedefs: catalog.typedefs,
            callbacks: catalog.callbacks
          )
        elsif call_node.name.to_s.end_with?("=")
          # For both .id = val and [:id] = val, the assigned value is the LAST argument
          val_node = call_node.arguments&.arguments&.last
          val_node ? scope&.type_of(val_node) : Rigor::Type::Combinator.top
        elsif (field_type = fields[call_node.name])
          Types.return_type_for(
            field_type,
            target: @target || :ffi,
            module_name: receiver_class,
            exceptions: @exceptions || [],
            typedefs: catalog.typedefs,
            callbacks: catalog.callbacks
          )
        end
      end

      node_rule Prism::CallNode do |node, _scope, path|
        Analyzer.ffx_diagnostics_for_call(node, path: path, target: @target || :ffi)
      end

      node_rule Prism::ClassNode do |node, _scope, path|
        Analyzer.ffx_diagnostics_for_class(node, path: path, target: @target || :ffi)
      end

      def init(_services)
        root = config["root"] || Dir.pwd
        @target = TargetDetector.detect(root: root, config: config)
        @exceptions = config["exceptions"] || []
      end

      def prepare(_services)
        root = config["root"] || Dir.pwd
        @target = TargetDetector.detect(root: root, config: config)
        @exceptions = config["exceptions"] || []
      end

      private

      # Every discovered name in both `dynamic_return receivers:` kinds (#701), for the two rules whose
      # blocks accept an instance and a class receiver alike.
      #
      # @param names — discovered class / module names, or nil when the catalog producer did not run
      def both_receiver_kinds(names)
        Array(names).flat_map { |name| [name, "singleton(#{name})"] }
      end
    end
  end
end

Rigor::Plugin.register(Rigor::Plugin::FFI)
