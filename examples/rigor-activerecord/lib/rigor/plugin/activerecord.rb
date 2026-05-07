# frozen_string_literal: true

require "rigor/plugin"

require_relative "activerecord/inflector"
require_relative "activerecord/schema_table"
require_relative "activerecord/schema_parser"
require_relative "activerecord/model_index"
require_relative "activerecord/model_discoverer"
require_relative "activerecord/analyzer"

module Rigor
  module Plugin
    # rigor-activerecord — types ActiveRecord finder + relation
    # calls against the project's `db/schema.rb` and discovered
    # AR model classes.
    #
    # ## Architecture
    #
    # Two cached producers per plugin run:
    #
    # 1. `:schema_table` reads `db/schema.rb` via the `IoBoundary`
    #    and parses it through {SchemaParser} into a
    #    {SchemaTable} mapping `table_name → { column_name →
    #    Column }`.
    # 2. `:model_index` walks every `.rb` file under the
    #    configured `model_search_paths`, finds class declarations
    #    whose direct superclass is in `model_base_classes`, and
    #    composes them with the schema table into a {ModelIndex}.
    #
    # Both producers ride `Plugin::Base#cache_for`. The descriptor
    # auto-includes the digests of every file the boundary read,
    # so editing `db/schema.rb` or any model file invalidates
    # exactly the right cache entry.
    #
    # The per-file `#diagnostics_for_file` hook delegates to
    # {Analyzer}, which walks Prism and emits diagnostics for
    # `Model.find` / `Model.find_by` / `Model.where` calls
    # against the index.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-activerecord
    #         config:
    #           schema_file: "db/schema.rb"
    #           model_search_paths: ["app/models"]
    #           model_base_classes: ["ApplicationRecord", "ActiveRecord::Base"]
    #
    # All three keys default to the values shown above. The class
    # name `Rigor::Plugin::Activerecord` (single capital R) is
    # intentional — keeps the constant lookup distinct from
    # `::ActiveRecord` even though the gem name is hyphenated.
    #
    # Note: this plugin is the seventh worked example. It does NOT
    # require `active_record` at runtime — it only reads project
    # source, the same way the other examples do. Rigor stays
    # decoupled from Rails.
    class Activerecord < Rigor::Plugin::Base
      manifest(
        id: "activerecord",
        version: "0.1.0",
        description: "Types ActiveRecord finders against the project's db/schema.rb and AR models.",
        config_schema: {
          "schema_file" => :string,
          "model_search_paths" => :array,
          "model_base_classes" => :array
        }
      )

      DEFAULT_SCHEMA_FILE = "db/schema.rb"
      DEFAULT_MODEL_SEARCH_PATHS = ["app/models"].freeze
      DEFAULT_MODEL_BASE_CLASSES = %w[ApplicationRecord ActiveRecord::Base].freeze

      # Cached: parsed schema table. The producer reads `@schema_file`
      # via `io_boundary.read_file` so the descriptor picks up the
      # digest, then parses through {SchemaParser}.
      producer :schema_table do |_params|
        contents = io_boundary.read_file(@schema_file)
        SchemaParser.parse(contents)
      end

      # Cached: model index. Walks every model file, then composes
      # the rows with the cached schema table.
      producer :model_index do |_params|
        rows = ModelDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @model_search_paths,
          base_classes: @model_base_classes
        ).discover
        ModelIndex.build(model_rows: rows, schema_table: schema_table_or_nil)
      end

      def init(_services)
        @schema_file = config.fetch("schema_file", DEFAULT_SCHEMA_FILE)
        @model_search_paths = Array(config.fetch("model_search_paths", DEFAULT_MODEL_SEARCH_PATHS)).map(&:to_s)
        @model_base_classes = Array(config.fetch("model_base_classes", DEFAULT_MODEL_BASE_CLASSES)).map(&:to_s)
        @schema_table = nil
        @model_index = nil
        @load_errors = []
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = model_index
        return load_error_diagnostics(path) if index.nil?
        return [] if index.empty?

        Analyzer.new(path: path, model_index: index).analyze(root).diagnostics
      end

      private

      def model_index
        return @model_index if @model_index

        table = schema_table_or_nil
        return nil if table.nil?

        # Walk model files first so the IoBoundary's digest list
        # captures them BEFORE `cache_for` snapshots the
        # descriptor (the same "read first, cache_for second"
        # pattern documented at the top of rigor-routes).
        ModelDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @model_search_paths,
          base_classes: @model_base_classes
        ).discover

        @model_index = cache_for(:model_index, params: {}).call
      rescue StandardError => e
        @load_errors << "model index build failed: #{e.class}: #{e.message}"
        nil
      end

      def schema_table_or_nil
        return @schema_table if @schema_table

        # Same pattern: read schema file via boundary, then call
        # cache_for so the descriptor includes the file digest.
        io_boundary.read_file(@schema_file)
        @schema_table = cache_for(:schema_table, params: {}).call
      rescue Plugin::AccessDeniedError => e
        @load_errors << "rigor-activerecord: #{e.message}"
        nil
      rescue Errno::ENOENT
        @load_errors << "rigor-activerecord: schema file `#{@schema_file}` not found; AR call checks skipped"
        nil
      rescue StandardError => e
        @load_errors << "rigor-activerecord: failed to parse `#{@schema_file}`: #{e.class}: #{e.message}"
        nil
      end

      def load_error_diagnostics(path)
        @load_errors.uniq.map do |message|
          Rigor::Analysis::Diagnostic.new(
            path: path,
            line: 1,
            column: 1,
            message: message,
            severity: :warning,
            rule: "load-error"
          )
        end
      end
    end

    Rigor::Plugin.register(Activerecord)
  end
end
