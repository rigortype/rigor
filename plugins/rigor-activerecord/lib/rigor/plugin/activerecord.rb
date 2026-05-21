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
        },
        produces: [:model_index],
        # ADR-25 — the bundled `ActiveRecord::Relation` RBS. It is
        # what `flow_contribution_for`'s relation-typed call sites
        # (`has_many` accessors, `Model.where`, scopes) dispatch
        # against.
        signature_paths: ["sig"]
      )

      DEFAULT_SCHEMA_FILE = "db/schema.rb"
      DEFAULT_MODEL_SEARCH_PATHS = ["app/models"].freeze
      DEFAULT_MODEL_BASE_CLASSES = %w[ApplicationRecord ActiveRecord::Base].freeze

      # The class the bundled `sig/active_record/relation.rbs`
      # describes; `flow_contribution_for` contributes
      # `ActiveRecord::Relation[Model]` for relation-returning
      # call sites (`has_many` accessors, `Model.where`, scopes).
      RELATION_CLASS_NAME = "ActiveRecord::Relation"

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

      # ADR-9 cross-plugin publication. Builds the model index
      # eagerly during the per-run `prepare(services)` pass and
      # publishes a flat Hash form to the shared fact store so
      # downstream Tier-2 consumers (rigor-actionpack Phase 1
      # strong-parameter validation, rigor-factorybot Phase 1
      # (c) attribute → column cross-check, future plugins
      # that need to know "what columns does class `User`
      # expose?") can read it without coupling to this
      # plugin's carrier classes.
      #
      # The published shape:
      #
      #     {
      #       "User" => { table: "users", columns: ["id", "name", "email"] },
      #       "Post" => { table: "posts", columns: ["id", "title", "body"] },
      #       ...
      #     }
      #
      # Consumers do `services.fact_store.read(plugin_id:
      # "activerecord", name: :model_index)` and look up by
      # class name. Discovery failures (missing schema,
      # unparseable models) leave the fact unpublished — the
      # consumer's own degrade path runs (typically a no-op).
      def prepare(services)
        index = model_index
        return if index.nil? || index.empty?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :model_index,
          value: index_to_published_hash(index)
        )
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = model_index
        if index.nil?
          # Project-global error (missing `db/schema.rb`, parse
          # failure, etc.) — emit once per run rather than once
          # per analyzed file. On a Redmine-shape project that
          # uses migrations only (no `schema.rb`), the old path
          # produced 346 identical load-errors; on a Solidus
          # monorepo (no top-level `schema.rb`), 999.
          return [] if @load_errors_emitted

          @load_errors_emitted = true
          return load_error_diagnostics(path)
        end
        return [] if index.empty?

        Analyzer.new(path: path, model_index: index).analyze(root).diagnostics
      end

      # v0.1.2 — return-type contribution. `Model.find(id)`
      # narrows the call site's return type to `Nominal[Model]`,
      # so chained calls (`User.find(1).name`) resolve through
      # the analyzer's normal dispatch instead of the RBS-level
      # untyped fall-back. `Model.find_by(...)` narrows to
      # `Nominal[Model] | nil` because Rails returns nil when no
      # row matches. `where` / `find_or_*` are intentionally
      # deferred — they return relations, and Rigor does not yet
      # carry an Enumerable-backed relation shape that would be
      # more precise than the RBS envelope.
      def flow_contribution_for(call_node:, scope:)
        return nil unless call_node.is_a?(Prism::CallNode)
        return nil if call_node.receiver.nil?

        index = model_index
        return nil if index.nil? || index.empty?

        return_type = class_call_return_type(call_node, index) ||
                      instance_call_return_type(call_node, scope, index)
        return nil if return_type.nil?

        Rigor::FlowContribution.new(
          return_type: return_type,
          provenance: Rigor::FlowContribution::Provenance.new(
            source_family: "plugin.#{manifest.id}",
            plugin_id: manifest.id,
            node: call_node,
            descriptor: nil
          )
        )
      end

      private

      def class_call_return_type(call_node, index)
        model_name = constant_receiver_name(call_node.receiver)
        return nil if model_name.nil?

        entry = index.find(model_name) || index.find("::#{model_name}")
        return nil if entry.nil?

        finder_return_type(call_node, entry) ||
          class_scope_return_type(call_node, entry)
      end

      # Class-side finders + the class-side relation entry points.
      # `find` / `find_by!` return the model; `find_by` adds the
      # `nil` arm; `where` / `all` / `order` / `limit` / `none`
      # open a relation. The relation then carries its element
      # type through any further chained query method via the
      # bundled `ActiveRecord::Relation` RBS.
      def finder_return_type(call_node, entry)
        case call_node.name
        when :find
          return nil if call_argument_count(call_node).zero?

          Rigor::Type::Combinator.nominal_of(entry.class_name)
        when :find_by!
          # The bang variant raises `RecordNotFound` instead of
          # returning `nil`, so the result is non-nullable.
          Rigor::Type::Combinator.nominal_of(entry.class_name)
        when :find_by
          Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.nominal_of(entry.class_name),
            Rigor::Type::Combinator.constant_of(nil)
          )
        when :where, :all, :order, :limit, :none
          relation_of(entry.class_name)
        end
      end

      # `Post.published` / `Post.recent(5)` — a user-declared
      # `scope` returns a relation of the model regardless of the
      # arguments it takes.
      def class_scope_return_type(call_node, entry)
        return nil unless entry.scope?(call_node.name)

        relation_of(entry.class_name)
      end

      # `ActiveRecord::Relation[Model]` — the type the bundled
      # `sig/active_record/relation.rbs` describes.
      def relation_of(model_class_name)
        Rigor::Type::Combinator.nominal_of(
          RELATION_CLASS_NAME,
          type_args: [Rigor::Type::Combinator.nominal_of(model_class_name)]
        )
      end

      # Instance-side navigation: when the call's receiver
      # resolves to `Nominal[Model]` and the method name matches
      # a discovered association OR a table column, the call site
      # gets a precise return type. Calls with arguments are
      # skipped — accessor / association calls take no args, and
      # argument forms (`user.posts(limit: 10)`, `user.name = x`)
      # route through Rails APIs this slice does not model.
      def instance_call_return_type(call_node, scope, index)
        return nil unless call_node.arguments.nil?

        receiver_type = scope.type_of(call_node.receiver)
        return nil unless receiver_type.is_a?(Rigor::Type::Nominal)

        entry = index.find(receiver_type.class_name) ||
                index.find("::#{receiver_type.class_name}")
        return nil if entry.nil?

        association_return_type(entry, call_node.name) ||
          column_return_type(entry, call_node.name)
      end

      # The return type for an association accessor. A `belongs_to`
      # / `has_one` singular association narrows to the target
      # model — `belongs_to` is required (non-`nil`) by default
      # since Rails 5 so it is `Nominal[Target]`, while `has_one`
      # (and an `optional: true` / `required: false` `belongs_to`)
      # adds the `nil` arm. A `has_many` / `has_and_belongs_to_many`
      # collection narrows to `ActiveRecord::Relation[Target]` so
      # chained query / iteration calls resolve. A polymorphic
      # association has no single static target and declines
      # rather than inventing a wrong type.
      def association_return_type(entry, method_name)
        association = entry.association(method_name)
        return nil if association.nil?
        return nil if association[:target].nil?

        case association[:kind]
        when :collection
          relation_of(association[:target])
        when :singular
          target = Rigor::Type::Combinator.nominal_of(association[:target])
          return target unless association[:nullable]

          Rigor::Type::Combinator.union(target, Rigor::Type::Combinator.constant_of(nil))
        end
      end

      # Instance-side column access. `user.name` on a
      # `Nominal[User]` receiver narrows to the column's value
      # type; `user.name?` (the ActiveRecord-generated predicate)
      # narrows to `bool`.
      #
      # The contributed type is deliberately NON-nullable even
      # though the DB column may permit `NULL`: Rails code calls
      # column accessors directly (`user.email.downcase`) as a
      # matter of course, and contributing `T | nil` would light
      # up that idiom with `possible-nil-receiver` across an
      # entire codebase. Under-reporting a nil column is a false
      # negative; over-reporting it is a false positive — and the
      # project ranks the latter as the worse failure.
      def column_return_type(entry, method_name)
        name = method_name.to_s
        predicate = name.end_with?("?")
        column_name = predicate ? name[0..-2] : name

        column = entry.column(column_name)
        return nil if column.nil?
        return bool_type if predicate

        ruby_type_to_type(column.ruby_type)
      end

      # Maps a `SchemaTable::Column#ruby_type` string to a Rigor
      # type. `"Object"` (json / jsonb / unrecognised column
      # types) declines — `Nominal[Object]` would be NARROWER
      # than the RBS-erased envelope and could surface false
      # `call.undefined-method` on a value whose real shape the
      # plugin cannot model.
      def ruby_type_to_type(ruby_type)
        case ruby_type
        when "bool" then bool_type
        when "Object", nil then nil
        else Rigor::Type::Combinator.nominal_of(ruby_type)
        end
      end

      # `true | false`, the structural shape RBS `bool` folds to.
      def bool_type
        @bool_type ||= Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.constant_of(true),
          Rigor::Type::Combinator.constant_of(false)
        )
      end

      def constant_receiver_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then constant_path_name(node)
        end
      end

      def constant_path_name(node)
        parts = []
        current = node
        while current.is_a?(Prism::ConstantPathNode)
          parts.unshift(current.name.to_s)
          current = current.parent
        end
        case current
        when nil then "::#{parts.join('::')}"
        when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
        end
      end

      def call_argument_count(node)
        return 0 if node.arguments.nil?

        node.arguments.arguments.size
      end

      # Marshal-clean Hash form for the cross-plugin fact
      # store. Consumers (rigor-actionpack Phase 1,
      # rigor-factorybot Phase 1 (c), ...) get a flat
      # `class_name → { table:, columns: }` map without
      # depending on this plugin's `ModelIndex` /
      # `SchemaTable::Column` carrier classes.
      def index_to_published_hash(index)
        index.entries.transform_values do |entry|
          {
            table: entry.table_name,
            columns: entry.columns.map(&:name).freeze,
            associations: entry.associations,
            enums: entry.enums,
            scopes: entry.scopes,
            validations: entry.validated_attributes,
            callbacks: entry.callbacks,
            aliases: entry.aliases
          }.freeze
        end.freeze
      end

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
