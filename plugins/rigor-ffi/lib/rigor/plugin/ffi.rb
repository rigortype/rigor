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
        description: "Models FFI::Library bindings, carriers, structs, callbacks, and ffx target compatibility.",
        config_schema: {
          "target" => { kind: :string, default: "auto" },
          "nominal_typedef_exceptions" => { kind: :array, default: [] }
        },
        signature_paths: ["sig"]
      )

      producer :ffi_catalog, watch: -> { [[".", "**/*.rb"]] } do |_params|
        FFIDiscoverer.new(root: @root, io_boundary: @io_boundary).discover
      end

      def init(services)
        @root = services.respond_to?(:root) ? services.root : nil
        @io_boundary = services.respond_to?(:io_boundary) ? services.io_boundary : nil
        @target = TargetDetector.detect(root: @root, config: config)
        @exceptions = Array(config.fetch("nominal_typedef_exceptions", [])).map(&:to_s)
      end

      def prepare(services)
        # Warm the catalog producer
        producer_value(:ffi_catalog)
      end

      def diagnostics_for_file(path:, scope:, root:)
        []
      end

      dynamic_return methods: -> { producer_value(:ffi_catalog)&.all_method_names || [] } do |call_node, _scope|
        catalog = producer_value(:ffi_catalog)
        next nil if catalog.nil?

        method_name = call_node.name
        facts = catalog.function_for(method_name)
        if facts && !facts.empty?
          fact = facts.first
          Types.return_type_for(
            fact.return_type,
            target: @target || :ffi,
            module_name: fact.receiver_name,
            exceptions: @exceptions || [],
            typedefs: catalog.typedefs
          )
        elsif (struct_match = catalog.structs.find { |_name, fields| fields.key?(method_name) })
          field_type = struct_match[1][method_name]
          Types.return_type_for(
            field_type,
            target: @target || :ffi,
            module_name: struct_match[0],
            exceptions: @exceptions || [],
            typedefs: catalog.typedefs
          )
        end
      end

      node_rule Prism::CallNode do |node, _scope, path|
        Analyzer.ffx_diagnostics_for_call(node, path: path, target: @target || :ffi)
      end

      node_rule Prism::ClassNode do |node, _scope, path|
        Analyzer.ffx_diagnostics_for_class(node, path: path, target: @target || :ffi)
      end
    end
  end
end

Rigor::Plugin.register(Rigor::Plugin::FFI)
