# frozen_string_literal: true

require "rigor/plugin"

require_relative "activerecord/schema_table"
require_relative "activerecord/schema_parser"
require_relative "activerecord/structure_sql_parser"
require_relative "activerecord/model_index"
require_relative "activerecord/model_discoverer"
require_relative "activerecord/analyzer"
require_relative "activerecord/effects"

module Rigor
  module Plugin
    # rigor-activerecord — types ActiveRecord finder + relation calls against the project's `db/schema.rb`
    # and discovered AR model classes.
    #
    # ## Architecture
    #
    # Two cached producers per plugin run:
    #
    # 1. `:schema_table` reads `db/schema.rb` via the `IoBoundary` and parses it through {SchemaParser} into
    #    a {SchemaTable} mapping `table_name → { column_name → Column }`. When `db/schema.rb` is absent it
    #    falls back to a PostgreSQL `db/structure.sql` (`schema_format = :sql` apps) via {StructureSqlParser}.
    # 2. `:model_index` walks every `.rb` file under the configured `model_search_paths`, finds class
    #    declarations whose direct superclass is in `model_base_classes`, and composes them with the schema
    #    table into a {ModelIndex}.
    #
    # Both producers ride `Plugin::Base#cache_for` (ADR-60 WD3 record-and-validate): each producer's
    # in-block boundary reads are captured into its dependency descriptor after the block runs, and
    # `model_index`'s `watch:` covers model-file additions, so editing `db/schema.rb`, editing any model, or
    # adding a new model file invalidates exactly the right cache entry.
    #
    # The per-file `#diagnostics_for_file` hook delegates to {Analyzer}, which walks Prism and emits
    # diagnostics for `Model.find` / `Model.find_by` / `Model.where` calls against the index.
    #
    # ## Reduced mode (no schema file)
    #
    # The schema gates the COLUMN surface and nothing else. When neither file is present — the DB-agnostic
    # Rails pattern of shipping raw migrations and gitignoring `db/schema.rb`, as Redmine does — the plugin
    # builds a columns-less {ModelIndex} from {ModelDiscoverer} output alone and keeps typing table names,
    # finders, scopes and associations off it. Column readers and column-keyed checks then decline exactly
    # as an unrecognised column does: `Analyzer` already treats an empty column set as "cannot check"
    # (view-backed models hit the same path on a schema-PRESENT project), and `#column_return_type` finds
    # no column and contributes nothing. The `:model_index` fact is deliberately NOT published in this mode
    # — see `#prepare`.
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
    # All three keys default to the values shown above. The class name `Rigor::Plugin::Activerecord` (single
    # capital R) is intentional — keeps the constant lookup distinct from `::ActiveRecord` even though the
    # gem name is hyphenated.
    #
    # Note: this plugin is the seventh worked example. It does NOT require `active_record` at runtime — it
    # only reads project source, the same way the other examples do. Rigor stays decoupled from Rails.
    class Activerecord < Rigor::Plugin::Base
      manifest(
        id: "activerecord",
        # 0.8.0, 2026-09-02 — a model declared `class ::User` is keyed by its de-rooted name (`"User"`) in
        # the {ModelIndex} and the published `:model_index` fact (#583). The version is part of the
        # producer cache KEY: a cached 0.7.0 index still keys such a model `"::User"`, and `ModelIndex#find`
        # now normalises every query to the de-rooted spelling, so serving that payload warm would miss the
        # model on every lookup until an unrelated model edit happened to invalidate the entry.
        #
        # 0.7.0, 2026-09-01 — `table_name` / `quoted_table_name` join the recognised class-side surface, and
        # `ModelIndex::Entry` gains the `table_name_exact` member that gates value-pinning. A Struct member
        # addition is not Marshal-compatible with the cached 0.6.0 payload, so the bump (part of the
        # producer cache key) is what keeps a warm run from loading it.
        #
        # 0.6.0, 2026-09-01 — reduced mode: a missing `db/schema.rb` / `db/structure.sql` degrades to a
        # columns-less {ModelIndex} instead of disabling the plugin. The version is part of the producer
        # cache KEY, so the bump is what stops a warm run from serving the pre-change payload (which,
        # having no `columns_known` ivar, would read as reduced mode on a schema-PRESENT project and
        # withhold the `:model_index` fact).
        #
        # 0.5.0, 2026-05-28 — implicit-self class-side AR call resolution: `select(:uri).group(:uri)` inside
        # a scope lambda body / class-method body now contributes `Relation[Model]` via `scope.self_type`
        # instead of falling through to `Kernel#select` (the IO multiplexer, `Array[String]` return). Plus
        # `:select` added to the relation-entry-point list.
        version: "0.8.0",
        description: "Types ActiveRecord finders against the project's db/schema.rb and AR models.",
        config_schema: {
          "schema_file" => { kind: :string, default: "db/schema.rb" },
          # `schema_format = :sql` projects (GitLab-class apps) commit a PostgreSQL `db/structure.sql`
          # instead of `db/schema.rb`. Used as the fallback schema source when `schema_file` is absent.
          "structure_sql_file" => { kind: :string, default: "db/structure.sql" },
          "model_search_paths" => { kind: :array, default: ["app/models"] },
          "model_base_classes" => { kind: :array, default: %w[ApplicationRecord ActiveRecord::Base] }
        },
        produces: [:model_index],
        # ADR-25 — the bundled `ActiveRecord::Relation` RBS that relation-typed call sites (`has_many`
        # accessors, `Model.where`, scopes) dispatch against.
        signature_paths: ["sig"],
        # ADR-26 — `ActiveRecord::Relation` is an "open" receiver: it delegates an unbounded set of
        # user-defined scopes / class methods to its model, so `call.undefined-method` must not fire for
        # it. `CheckRules` reads this manifest field and skips the rule for the class.
        open_receivers: ["ActiveRecord::Relation"],
        # ADR-103 WD2 / WD10 (#387) — the effect layer. rigor-activerecord models ActiveRecord, which is
        # part of Rails, so it opens the framework's own `rails.*` root rather than one named after the
        # plugin; `effect_root:` is granted only because the engine bundles this plugin
        # ({Rigor::Plugin::FirstParty}). Every row's justification is in {Effects}, and the
        # `ActiveRecord::Relation` half is in the bundled `sig/active_record/relation.rbs` instead —
        # tier 1, because the plugin already ships that signature.
        effect_root: "rails",
        effect_labels: ["rails.schema.write"],
        effect_attributions: Effects.attributions,
        effect_edges: Effects.edges
      )

      # The class the bundled `sig/active_record/relation.rbs` describes; `dynamic_return` contributes
      # `ActiveRecord::Relation[Model]` for relation-returning call sites (`has_many` accessors,
      # `Model.where`, scopes).
      RELATION_CLASS_NAME = "ActiveRecord::Relation"

      # Cached: parsed schema table. The producer reads `@schema_file` via `io_boundary.read_file` so the
      # descriptor picks up the digest, then parses through {SchemaParser}. When `db/schema.rb` is absent
      # the producer falls back to a PostgreSQL `db/structure.sql` (`schema_format = :sql` apps) parsed
      # through {StructureSqlParser} — both reads are captured into the record-and-validate descriptor.
      producer :schema_table do |_params|
        SchemaParser.parse(io_boundary.read_file(@schema_file))
      rescue Errno::ENOENT
        StructureSqlParser.parse(io_boundary.read_file(@structure_sql_file))
      end

      # Cached: model index. Walks every model file, then composes the rows with the cached schema table.
      # `watch:` (ADR-60 WD3) covers model-file additions; the discoverer's in-block reads are captured
      # into the record-and-validate dependency descriptor after the block runs.
      producer :model_index, watch: -> { [[@model_search_paths, "**/*.rb"]] } do |_params|
        discoverer = ModelDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @model_search_paths,
          base_classes: @model_base_classes
        )
        rows = discoverer.discover
        ModelIndex.build(
          model_rows: rows, schema_table: schema_table_or_nil,
          type_override_columns: discoverer.type_override_columns
        )
      end

      def init(_services)
        @schema_file = config.fetch("schema_file")
        @structure_sql_file = config.fetch("structure_sql_file")
        @model_search_paths = Array(config.fetch("model_search_paths")).map(&:to_s)
        @model_base_classes = Array(config.fetch("model_base_classes")).map(&:to_s)
        @schema_table = nil
        @schema_load_attempted = false
        @model_index = nil
        @load_errors = []
      end

      # ADR-9 cross-plugin publication. Builds the model index eagerly during the per-run
      # `prepare(services)` pass and publishes a flat Hash form to the shared fact store so downstream
      # Tier-2 consumers (rigor-actionpack Phase 1 strong-parameter validation, rigor-factorybot Phase 1
      # (c) attribute → column cross-check, future plugins that need to know "what columns does class
      # `User` expose?") can read it without coupling to this plugin's carrier classes.
      #
      # The published shape:
      #
      #     {
      #       "User" => { table: "users", columns: ["id", "name", "email"] },
      #       "Post" => { table: "posts", columns: ["id", "title", "body"] },
      #       ...
      #     }
      #
      # Consumers do `services.fact_store.read(plugin_id: "activerecord", name: :model_index)` and look up
      # by class name — the DE-ROOTED constant path (`"User"`, `"Admin::User"`), never `"::User"`, however
      # the model was declared (#583; see {ModelDiscoverer}). Discovery failures (missing schema,
      # unparseable models) leave the fact unpublished — the consumer's own degrade path runs (typically a
      # no-op).
      def prepare(services)
        index = model_index
        return if index.nil? || index.empty?
        # Reduced mode stays UNPUBLISHED. Every consumer reads `columns:` as authoritative and fires on a
        # key missing from it — rigor-actionpack's `permit(:title)` check and rigor-shoulda-matchers'
        # `have_db_column(:title)` / `validate_presence_of(:title)` matchers both do — so publishing the
        # reduced index's empty column set would convert this precision win into a false positive on every
        # strong-parameter key and every column matcher in the project. Withholding it leaves those
        # consumers exactly where they are today on a schema-less target: silent.
        return unless index.columns_known?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :model_index,
          value: index_to_published_hash(index)
        )
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = model_index
        # The schema-load disclosure is independent of whether an index was built: reduced mode still
        # produces one (and still analyzes), while a genuine index failure produces one and nothing else.
        diagnostics = consume_load_error_diagnostics(path)
        return diagnostics if index.nil? || index.empty?
        return diagnostics if migration_path?(path)

        diagnostics.concat(Analyzer.new(path: path, model_index: index).analyze(root).diagnostics)
      end

      # Rails migration files (`db/migrate/<timestamp>_*.rb`) and post-migration files
      # (`db/post_migrate/`) reference the EVOLVING schema at the time the migration was written —
      # `User.where(admin: ...)` is valid when the migration ran on a schema that still had the `admin`
      # column, even though the current `db/schema.rb` no longer carries it. Validating these files
      # against the CURRENT schema is a category error; the column diagnostics MUST stay silent.
      MIGRATION_PATH_PATTERNS = [
        %r{(\A|/)db/migrate/},
        %r{(\A|/)db/post_migrate/}
      ].freeze
      private_constant :MIGRATION_PATH_PATTERNS

      def migration_path?(path)
        return false if path.nil?

        path_s = path.to_s
        MIGRATION_PATH_PATTERNS.any? { |pattern| path_s.match?(pattern) }
      end

      # The class-side finder / relation entry-point names `finder_return_type` recognises. Static half of
      # the `dynamic_return` name gate; the run-time half comes from the model index (scopes,
      # associations, columns).
      FINDER_METHOD_NAMES = %i[
        find find_by! find_by where all order limit none select
        table_name quoted_table_name
      ].freeze
      private_constant :FINDER_METHOD_NAMES

      # Return-type contribution via the run-time `methods:` name gate (ADR-52 slice 5b). `Model.find(id)`
      # narrows the call site's return type to `Nominal[Model]`, so chained calls (`User.find(1).name`)
      # resolve through the analyzer's normal dispatch instead of the RBS-level untyped fall-back; scopes,
      # association accessors, and column readers narrow per the paths below.
      #
      # WHY a method-name gate and not `receivers:` — the ADR-52 "rigor-activerecord blocker": a project
      # model not in RBS types its constant as `Dynamic[top]`, so a receiver-type gate declines exactly the
      # calls this plugin exists for. A *name* gate never reads the receiver type; the block keeps the
      # plugin's own AST-constant / `self_type` / `type_of` resolution, so the Dynamic-constant case still
      # reaches it (the same shape as rigor-sorbet's catalog path). The set — the static finder names ∪
      # every scope, association, and column name (plus `column?` predicate forms) the model index
      # discovered — is exactly the union of names the four resolution paths below can return a type for,
      # so gating on it is byte-identical to the old ungated hook. It is broad (`name`, `id`, …), but
      # membership is one Set probe and the expensive block runs only on candidate hits.
      dynamic_return methods: -> { recognised_method_names } do |call_node, scope|
        contribution_return_type(call_node, scope)
      end

      private

      # The run-time name gate: finders ∪ scopes ∪ associations ∪ column readers (+ `?` predicates).
      # Resolved lazily on first dispatch (after `#prepare` built the index), memoised by the engine.
      # Returns [] when discovery found nothing — the gate then declines every call, matching the old
      # hook's `index.nil? || index.empty?` early return.
      def recognised_method_names
        index = model_index
        return [] if index.nil? || index.empty?

        names = FINDER_METHOD_NAMES.dup
        index.entries.each_value do |entry|
          names.concat(entry.scopes.map(&:to_sym))
          names.concat(entry.association_names.map(&:to_sym))
          entry.column_names.each do |column|
            names << column.to_sym
            names << :"#{column}?"
          end
        end
        names
      end

      # Resolution body for `dynamic_return` — same four-path order, returning the bare type the contract
      # expects.
      def contribution_return_type(call_node, scope)
        return nil unless call_node.is_a?(Prism::CallNode)

        index = model_index
        return nil if index.nil? || index.empty?

        if call_node.receiver
          class_call_return_type(call_node, index) ||
            relation_call_return_type(call_node, scope, index) ||
            instance_call_return_type(call_node, scope, index)
        else
          implicit_self_class_call_return_type(call_node, scope, index)
        end
      end

      def class_call_return_type(call_node, index)
        model_name = constant_receiver_name(call_node.receiver)
        return nil if model_name.nil?

        # A rooted receiver (`::User.find`) renders as `"::User"`; `ModelIndex#find` normalises it.
        entry = index.find(model_name)
        return nil if entry.nil?

        finder_return_type(call_node, entry) ||
          class_scope_return_type(call_node, entry)
      end

      # Implicit-self class-side call: `select(:uri)` / `where(active: true)` inside a `def
      # self.<method>` body, a class body, or a scope lambda body (`scope :x, -> { ... }`). The
      # surrounding `self_type` is `Singleton[Model]` in all three cases, so the same finder / scope /
      # relation entry-point resolution that handles `Model.where(...)` applies.
      #
      # Without this, `select(:uri)` inside a class body falls through to RBS dispatch on
      # `Singleton[Account]`, which finds `Kernel#select` (the IO multiplexer) at `core/kernel.rbs` — its
      # `Array[String]` return masks the AR class-side `select`'s relation return type, so the canonical
      # scope-body idiom
      #
      #   scope :duplicate_uris, -> { select(:uri).group(:uri) }
      #
      # types `select(:uri)` as `Array[String]` and the chained `.group` as `undefined-method`.
      def implicit_self_class_call_return_type(call_node, scope, index)
        return nil if scope.nil?

        self_type = scope.self_type
        return nil unless self_type.is_a?(Rigor::Type::Singleton)

        entry = index.find(self_type.class_name)
        return nil if entry.nil?

        finder_return_type(call_node, entry) ||
          class_scope_return_type(call_node, entry)
      end

      # Class-side finders + the class-side relation entry points. `find` / `find_by!` return the model;
      # `find_by` adds the `nil` arm; `where` / `all` / `order` / `limit` / `none` open a relation. The
      # relation then carries its element type through any further chained query method via the bundled
      # `ActiveRecord::Relation` RBS.
      def finder_return_type(call_node, entry)
        case call_node.name
        when :find
          return nil if call_argument_count(call_node).zero?

          Rigor::Type::Combinator.nominal_of(entry.class_name)
        when :find_by!
          # The bang variant raises `RecordNotFound` instead of returning `nil`, so the result is
          # non-nullable.
          Rigor::Type::Combinator.nominal_of(entry.class_name)
        when :find_by
          Rigor::Type::Combinator.union(
            Rigor::Type::Combinator.nominal_of(entry.class_name),
            Rigor::Type::Combinator.constant_of(nil)
          )
        when :where, :all, :order, :limit, :none, :select
          # `:select` was added to close Mastodon's
          # `scope :duplicate_uris, -> { select(:uri).group(:uri).having(...) }` shape: the implicit-self
          # `select(:uri)` inside the scope lambda body had been resolving to `Kernel#select` (IO
          # multiplexer, return `Array[String]`), masking the AR class-side relation entry point. The rest
          # of the query DSL chains through the bundled `ActiveRecord::Relation` RBS once a relation is
          # open.
          relation_of(entry.class_name)
        when :table_name
          table_name_return_type(entry)
        when :quoted_table_name
          # Quoting is adapter-dependent — `"users"` on PostgreSQL, backticked on MySQL — so unlike
          # `table_name` the exact string is not derivable from project source even when the bare name is.
          Rigor::Type::Combinator.nominal_of("String")
        end
      end

      # `Model.table_name` is a String either way; whether it is safe to VALUE-PIN turns on how the name was
      # derived. `Entry#table_name_exact?` holds ONLY for a name the source declared as a String literal
      # (`self.table_name = "…"`, inherited down an STI chain, and not overridden by a computed one). An
      # inflected name is never pinned, however plausible: a `table_name_prefix` / `table_name_suffix` on
      # the namespace, an abstract class (whose real answer is `nil`), and a project-custom inflection rule
      # all silently change the real name, and `Constant["users"]` on any of them is a wrong precise type
      # that value-dependent folding downstream acts on — `Model.table_name == <real name>` folds
      # always-falsey, an error on working code.
      #
      # The schema is deliberately NOT admitted as corroboration for an inflected name. A table existing
      # does not make it THIS model's table: with a `table_name_prefix = "app_"`, `User` reads `app_users`
      # while a `users` table declared by another model would "confirm" the inflection. Prefix / suffix /
      # namespace derivation is not reachably airtight, and a smaller set of pins beats a wrong one.
      # Widening to `String` is monotone imprecision — and it still closes the opacity the call site had,
      # which is the whole measured win.
      #
      # `String` rather than `String | nil` for the abstract-class case follows the same call as
      # `#column_return_type`: under-reporting nil is a false negative, over-reporting it lights up
      # `possible-nil-receiver` on the ordinary idiom, and this project ranks the latter as the worse
      # failure.
      def table_name_return_type(entry)
        return Rigor::Type::Combinator.nominal_of("String") unless entry.table_name_exact?

        Rigor::Type::Combinator.constant_of(entry.table_name)
      end

      # `Post.published` / `Post.recent(5)` — a user-declared `scope` returns a relation of the model
      # regardless of the arguments it takes.
      def class_scope_return_type(call_node, entry)
        return nil unless entry.scope?(call_node.name)

        relation_of(entry.class_name)
      end

      # `ActiveRecord::Relation[Model]` — the type the bundled `sig/active_record/relation.rbs` describes.
      # The class is declared `open_receivers` in the manifest, so a chained scope call the bundled RBS
      # cannot enumerate does not surface as `call.undefined-method` (ADR-26).
      def relation_of(model_class_name)
        Rigor::Type::Combinator.nominal_of(
          RELATION_CLASS_NAME,
          type_args: [Rigor::Type::Combinator.nominal_of(model_class_name)]
        )
      end

      # A scope invoked on an already-typed relation (`User.where(active: true).published`) keeps the
      # relation type through the chain. The bundled `ActiveRecord::Relation` RBS cannot enumerate
      # user-defined scopes, so without this the chain would lose its element type after the first scope
      # call. Non-scope methods decline — the RBS tier resolves `where` / `order` / `each` / `first`
      # precisely. Scopes may take arguments (`relation.recent(5)`), so — unlike `instance_call_return_type`
      # — argument calls are not skipped.
      #
      # The cheap `scope_name?` pre-check is load-bearing: it gates the `scope.type_of(receiver)` call so
      # the receiver type is computed ONLY when the method name could be a scope. `type_of` on a call
      # receiver re-enters dispatch, and calling it for every call node in a long method chain is
      # pathologically expensive — the pre-check keeps the cost off the hot path.
      def relation_call_return_type(call_node, scope, index)
        return nil if call_node.receiver.nil?
        return nil unless scope_name?(call_node.name, index)

        model_name = relation_element_class_name(scope.type_of(call_node.receiver))
        return nil if model_name.nil?

        entry = index.find(model_name)
        return nil if entry.nil?
        return nil unless entry.scope?(call_node.name)

        relation_of(model_name)
      end

      # Whether `name` is a declared `scope` on ANY model in the index. A run-lifetime memoised Set so the
      # per-call check in `relation_call_return_type` stays O(1).
      def scope_name?(name, index)
        @all_scope_names ||= index.entries.each_value.flat_map(&:scopes).to_set
        @all_scope_names.include?(name.to_s)
      end

      # When `type` is `ActiveRecord::Relation[Nominal[Model]]`, returns the model class name; nil for
      # any other type.
      def relation_element_class_name(type)
        return nil unless type.is_a?(Rigor::Type::Nominal)
        return nil unless type.class_name == RELATION_CLASS_NAME

        element = type.type_args&.first
        element.class_name if element.is_a?(Rigor::Type::Nominal)
      end

      # Instance-side navigation: when the call's receiver resolves to `Nominal[Model]` and the method name
      # matches a discovered association OR a table column, the call site gets a precise return type.
      # Calls with arguments are skipped — accessor / association calls take no args, and argument forms
      # (`user.posts(limit: 10)`, `user.name = x`) route through Rails APIs this slice does not model.
      def instance_call_return_type(call_node, scope, index)
        return nil unless call_node.arguments.nil?

        receiver_type = scope.type_of(call_node.receiver)
        return nil unless receiver_type.is_a?(Rigor::Type::Nominal)

        entry = index.find(receiver_type.class_name)
        return nil if entry.nil?

        association_return_type(entry, call_node.name) ||
          column_return_type(entry, call_node.name)
      end

      # The return type for an association accessor. A `belongs_to` / `has_one` singular association
      # narrows to the target model — `belongs_to` is required (non-`nil`) by default since Rails 5 so it
      # is `Nominal[Target]`, while `has_one` (and an `optional: true` / `required: false` `belongs_to`)
      # adds the `nil` arm. A `has_many` / `has_and_belongs_to_many` collection narrows to
      # `ActiveRecord::Relation[Target]` so chained query / iteration calls resolve. A polymorphic
      # association has no single static target and declines rather than inventing a wrong type.
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

      # Instance-side column access. `user.name` on a `Nominal[User]` receiver narrows to the column's
      # value type; `user.name?` (the ActiveRecord-generated predicate) narrows to `bool`.
      #
      # The contributed type is deliberately NON-nullable even though the DB column may permit `NULL`:
      # Rails code calls column accessors directly (`user.email.downcase`) as a matter of course, and
      # contributing `T | nil` would light up that idiom with `possible-nil-receiver` across an entire
      # codebase. Under-reporting a nil column is a false negative; over-reporting it is a false positive
      # — and the project ranks the latter as the worse failure.
      def column_return_type(entry, method_name)
        name = method_name.to_s
        predicate = name.end_with?("?")
        column_name = predicate ? name[0..-2] : name

        column = entry.column(column_name)
        return nil if column.nil?
        return bool_type if predicate

        inner = ruby_type_to_type(column.ruby_type)
        return nil if inner.nil?

        column.array? ? Rigor::Type::Combinator.nominal_of("Array", type_args: [inner]) : inner
      end

      # Maps a `SchemaTable::Column#ruby_type` string to a Rigor type. `"Object"` (json / jsonb /
      # unrecognised column types) declines — `Nominal[Object]` would be NARROWER than the RBS-erased
      # envelope and could surface false `call.undefined-method` on a value whose real shape the plugin
      # cannot model.
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

      # Marshal-clean Hash form for the cross-plugin fact store. Consumers (rigor-actionpack Phase 1,
      # rigor-factorybot Phase 1 (c), rigor-shoulda-matchers, ...) get a flat `class_name → { table:,
      # columns: }` map without depending on this plugin's `ModelIndex` / `SchemaTable::Column` carrier
      # classes. The keys are the index's own — de-rooted constant paths — and the consumers key into the
      # Hash directly with the plain rendering of the constant they anchor on, with no two-spelling retry
      # (#583).
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

        # A missing schema no longer disables the plugin. `schema_table_or_nil` is still called here — not
        # for its return value (the producer block calls it again, memoised), but because a cache HIT skips
        # the producer block entirely and the reduced-mode disclosure would then never be recorded on a warm
        # run.
        schema_table_or_nil
        # ADR-60 WD3 record-and-validate: the producer's own in-block `ModelDiscoverer` reads are
        # captured into the dependency descriptor after the block runs, and the producer's `watch:` covers
        # model-file additions — so no priming walk is needed (it used to run the discover twice).
        @model_index = cache_for(:model_index, params: {}).call
      rescue StandardError => e
        @load_errors << { message: "model index build failed: #{e.class}: #{e.message}", severity: :warning }
        nil
      end

      def schema_table_or_nil
        return @schema_table if @schema_table
        # Memoize the *failure*, not just the success: `model_index` (and thus this method) is invoked per
        # AR call site, so a missing / unreadable schema file would otherwise re-attempt the read and
        # append a fresh interpolated error string to `@load_errors` on every call. On a large Rails app
        # that grew `@load_errors` to millions of retained strings (measured: 4.2 M strings / ~1.5 GB on
        # Redmine). One attempt is enough.
        return nil if @schema_load_attempted

        @schema_load_attempted = true
        # ADR-60 WD3 record-and-validate: the producer reads `@schema_file` in-block, and that read is
        # captured into the dependency descriptor after the block runs — so no priming read is needed
        # here.
        @schema_table = cache_for(:schema_table, params: {}).call
      rescue Plugin::AccessDeniedError => e
        @load_errors << { message: "rigor-activerecord: #{e.message}#{REDUCED_MODE_SUFFIX}",
                          severity: :warning }
        nil
      rescue Errno::ENOENT
        # NOT an error: a project that commits raw migrations only and gitignores `db/schema.rb` is the
        # DB-agnostic Rails pattern, not a misconfiguration. The plugin still types finders, scopes,
        # associations and table names off the discovered models, so this is a disclosure of REDUCED
        # capability rather than a failure — `:info`, the grade the plugins use for "here is what I
        # recognised", not `:warning`, the grade they use for "I could not run".
        @load_errors << { message: "rigor-activerecord: schema file `#{@schema_file}` (or " \
                                   "`#{@structure_sql_file}`) not found#{REDUCED_MODE_SUFFIX}",
                          severity: :info }
        nil
      rescue StandardError => e
        # A schema that EXISTS but does not parse is a real, actionable problem — the user meant it to be
        # read. Reduced mode still applies, but the disclosure stays a warning.
        @load_errors << { message: "rigor-activerecord: failed to parse `#{@schema_file}`: " \
                                   "#{e.class}: #{e.message}#{REDUCED_MODE_SUFFIX}",
                          severity: :warning }
        nil
      end

      # The half of every schema-load disclosure that says what the plugin still does. Kept as one string so
      # the three paths above cannot drift on the description of the mode they all land in.
      REDUCED_MODE_SUFFIX = "; typing models from source only — column checks " \
                            "(`where(col:)`, column readers) are skipped"
      private_constant :REDUCED_MODE_SUFFIX

      # Project-global disclosures, emitted once per run on the first analyzed file rather than once per
      # file. On a Redmine-shape project (migrations only, no `schema.rb`) the per-file form produced 346
      # identical rows; on a Solidus monorepo, 999.
      def consume_load_error_diagnostics(path)
        return [] if @load_errors_emitted

        @load_errors_emitted = true
        @load_errors.uniq.map do |error|
          Rigor::Analysis::Diagnostic.new(
            path: path,
            line: 1,
            column: 1,
            message: error.fetch(:message),
            severity: error.fetch(:severity),
            rule: "load-error"
          )
        end
      end
    end

    Rigor::Plugin.register(Activerecord)
  end
end
