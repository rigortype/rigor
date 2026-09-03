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
        version: "0.1.0",
        description: "Models FFI library bindings, struct layouts, callbacks, carrier types, and ffx target compatibility.",
        signature_paths: ["sig"]
      )

      producer :ffi_catalog do
        root = config["root"] || Dir.pwd
        Discoverer.discover(root: root)
      end

      # Dynamic return rule for attached FFI functions
      # Gated on known FFI library receivers and attached function names
      dynamic_return receivers: -> { producer_value(:ffi_catalog)&.libraries&.to_a || [] },
                     methods: -> { producer_value(:ffi_catalog)&.function_method_names&.to_a || [] } do |call_node, scope|
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
      dynamic_return receivers: -> { producer_value(:ffi_catalog)&.struct_names || [] },
                     methods: -> { producer_value(:ffi_catalog)&.struct_field_names&.to_a || [] } do |call_node, scope|
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
          scope&.type_of(call_node.arguments&.arguments&.first) || Rigor::Type::Combinator.top
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

      def init(services)
        @target = TargetDetector.detect(root: services.project_root, config: config)
        @exceptions = config["exceptions"] || []
      end

      def prepare(services)
        @target = TargetDetector.detect(root: services.project_root, config: config)
        @exceptions = config["exceptions"] || []
      end

      def diagnostics_for_file(path:, scope:, root:)
        []
      end
    end
  end
end

Rigor::Plugin.register(Rigor::Plugin::FFI)
