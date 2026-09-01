# frozen_string_literal: true

# Integration spec for `plugins/rigor-activerecord/`. Reference coverage for the most architecturally complete
# v0.1.0 plugin example — combines `rigor-routes`-style IoBoundary + cache producer (twice — schema and model
# index), `rigor-lisp-eval`-style Prism DSL interpretation (the schema parser), and `rigor-statesman`-style
# two-pass discover-then-validate.

require "spec_helper"
require "fileutils"
require "tmpdir"

# `ACTIVERECORD_PLUGIN_LIB` is also defined by `factorybot_plugin_spec.rb` (which consumes the activerecord
# plugin's `:model_index` facts). Guard against the double definition so running both specs in the same
# process does not warn `already initialized constant`.
unless defined?(ACTIVERECORD_PLUGIN_LIB)
  ACTIVERECORD_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
end
$LOAD_PATH.unshift(ACTIVERECORD_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIVERECORD_PLUGIN_LIB)
require "rigor-activerecord"

DEFAULT_SCHEMA = <<~SCHEMA
  ActiveRecord::Schema[8.0].define(version: 2026_05_07_000000) do
    create_table "users", force: :cascade do |t|
      t.string  "name", null: false
      t.string  "email", null: false
      t.boolean "admin"
      t.timestamps
    end

    create_table "posts", force: :cascade do |t|
      t.string "title"
      t.text   "body"
      t.references "user", foreign_key: true
      t.timestamps
    end
  end
SCHEMA

DEFAULT_MODELS = {
  "app/models/application_record.rb" => <<~RUBY,
    class ApplicationRecord
    end
  RUBY
  "app/models/user.rb" => <<~RUBY,
    class User < ApplicationRecord
    end
  RUBY
  "app/models/post.rb" => <<~RUBY
    class Post < ApplicationRecord
    end
  RUBY
}.freeze

USER_RBS_FOR_NARROWING = <<~RBS
  class User
    attr_accessor name: String
    attr_accessor email: String
  end
RBS

RSpec.describe "plugins/rigor-activerecord" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Activerecord }

  # `schema: nil` materialises NO `db/schema.rb`, which is how the reduced-mode examples build a project
  # that ships models but no committed schema (the DB-agnostic Rails pattern).
  def run_ar(source, schema: DEFAULT_SCHEMA, models: DEFAULT_MODELS, plugin_config: nil)
    files = models.dup
    files["db/schema.rb"] = schema if schema
    plugin_entry = plugin_config ? { "gem" => "rigor-activerecord", "config" => plugin_config } : nil
    run_plugin(source: source, plugin_entry: plugin_entry, files: files)
  end

  # Materialises the project files, runs the analyser directly, and returns `[result, model_index]` so the
  # AR-extension specs can assert against BOTH the diagnostic stream and the structured per-model state (enums
  # / scopes / validations / callbacks). The `model_index` accessor isn't surfaced through `run_plugin` because
  # the other plugin examples don't need it.
  def run_ar_with_index(source, models:, schema:)
    files = { "demo.rb" => source }.merge(models)
    files["db/schema.rb"] = schema if schema
    Dir.mktmpdir do |dir|
      materialize_files(dir, files)
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new(
          "paths" => ["demo.rb"],
          "plugins" => ["rigor-activerecord"]
        )
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          collect_stats: false,
          plugin_requirer: build_plugin_requirer
        )
        result = runner.run
        plugin = runner.plugin_registry.find("activerecord")
        [result, plugin&.send(:model_index)]
      end
    end
  end

  describe "recognised AR finder calls" do
    it "annotates `Model.find(id)` with the resolved table" do
      diags = plugin_diagnostics(run_ar("User.find(1)\n"))
      info = diags.find { |d| d.rule == "model-call" }
      expect(info.severity).to eq(:info)
      expect(info.message).to eq("`User.find` returns User (table: `users`)")
      expect(info.qualified_rule).to eq("plugin.activerecord.model-call")
    end

    it "annotates `Model.find_by(col: v)` with the matched column" do
      diags = plugin_diagnostics(run_ar("User.find_by(email: 'a')\n"))
      expect(diags.first.message).to eq("`User.find_by` (:email) on table `users`")
    end

    it "annotates `Model.where(col: v)` with the matched column" do
      diags = plugin_diagnostics(run_ar("User.where(admin: true)\n"))
      expect(diags.first.message).to eq("`User.where` (:admin) on table `users`")
    end

    it "recognises `t.references` columns as `<name>_id`" do
      diags = plugin_diagnostics(run_ar("Post.where(user_id: 1)\n"))
      expect(diags.first.message).to eq("`Post.where` (:user_id) on table `posts`")
    end

    it "uses the Inflector to derive `User → users` / `Post → posts`" do
      diags = plugin_diagnostics(run_ar("Post.find(42)\n"))
      expect(diags.first.message).to include("table: `posts`")
    end
  end

  describe "migration files are excluded from column validation" do
    # Rails migration files (`db/migrate/<timestamp>_*.rb`) and post-migration files reference the EVOLVING
    # schema at the time the migration ran. The current `db/schema.rb` may not have the columns those files
    # mention (the migration's purpose was often to add/remove them). Validating these files against the
    # current schema is a category error — the AR plugin must stay silent on them.

    let(:migration_source) { "Account.where(suspended: true)\n" }

    it "stays silent on `db/migrate/<timestamp>_*.rb` even when columns don't exist" do
      Dir.mktmpdir do |dir|
        plugin_class = Rigor::Plugin::Activerecord
        materialize_files(dir, "db/schema.rb" => DEFAULT_SCHEMA)
        FileUtils.mkdir_p(File.join(dir, "db", "migrate"))
        migration_path = File.join(dir, "db", "migrate", "20240101000001_test_migration.rb")
        File.write(migration_path, migration_source)
        Dir.chdir(dir) do
          configuration = Rigor::Configuration.new(
            "paths" => [migration_path],
            "plugins" => ["rigor-activerecord"]
          )
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil,
            plugin_requirer: lambda { |name|
              Rigor::Plugin.register(plugin_class) if File.basename(name, ".rb") == "rigor-activerecord"
              true
            }
          )
          result = runner.run
          ar_diags = result.diagnostics.select { |d| d.source_family == "plugin.activerecord" }
          # Only the schema-loading info / load-error diagnostics may pass through; no per-file column errors.
          expect(ar_diags.select { |d| d.rule == "unknown-column" }).to be_empty
        end
      end
    end

    it "stays silent on `db/post_migrate/` files too" do
      Dir.mktmpdir do |dir|
        plugin_class = Rigor::Plugin::Activerecord
        materialize_files(dir, "db/schema.rb" => DEFAULT_SCHEMA)
        FileUtils.mkdir_p(File.join(dir, "db", "post_migrate"))
        path = File.join(dir, "db", "post_migrate", "20240102000001_cleanup.rb")
        File.write(path, migration_source)
        Dir.chdir(dir) do
          configuration = Rigor::Configuration.new(
            "paths" => [path],
            "plugins" => ["rigor-activerecord"]
          )
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil,
            plugin_requirer: lambda { |name|
              Rigor::Plugin.register(plugin_class) if File.basename(name, ".rb") == "rigor-activerecord"
              true
            }
          )
          ar_diags = runner.run.diagnostics.select { |d| d.source_family == "plugin.activerecord" }
          expect(ar_diags.select { |d| d.rule == "unknown-column" }).to be_empty
        end
      end
    end

    it "still fires unknown-column on a regular app/ file (precision floor)" do
      # `:emial` typo on User — pattern from the surrounding `unknown-column diagnostics` block, known to fire.
      diags = plugin_diagnostics(run_ar("User.where(emial: 'a')\n"))
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err).not_to be_nil
    end
  end

  describe "unknown-column diagnostics" do
    it "errors on a typo with a Levenshtein-suggested name" do
      diags = plugin_diagnostics(run_ar("User.where(emial: 'a')\n"))
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err.severity).to eq(:error)
      expect(err.message).to include("unknown column `emial`")
      expect(err.message).to include("did you mean `:email`?")
    end

    it "errors without a hint when no column is close enough" do
      diags = plugin_diagnostics(run_ar("User.where(foo_bar_baz_quux: 1)\n"))
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err.message).not_to include("did you mean")
    end

    it "fires once per unknown key in a multi-key call" do
      diags = plugin_diagnostics(run_ar("Post.where(title: 'x', invented: true)\n"))
      errors = diags.select { |d| d.rule == "unknown-column" }
      expect(errors.size).to eq(1)
      expect(errors.first.message).to include("`invented`")
    end

    it "does not fire on a nested / joined-table condition (`where(assoc: { ... })`)" do
      # `where(posts: { title: 'x' })` is a join condition — `posts` names a joined table, not a column on
      # `User` — so it must not read as an unknown column. Rails resolves the nested hash through the join.
      diags = plugin_diagnostics(run_ar("User.where(posts: { title: 'x' })\n"))
      expect(diags.find { |d| d.rule == "unknown-column" }).to be_nil
    end

    it "still fires unknown-column when the value is a non-hash literal" do
      # An Array value is an IN query on a real column, not a nested condition — a typo'd key still fires.
      diags = plugin_diagnostics(run_ar("User.where(rols: ['a', 'b'])\n"))
      expect(diags.find { |d| d.rule == "unknown-column" }).not_to be_nil
    end
  end

  describe "type-overridden columns (serialize / mount_uploader / custom attribute)" do
    # A `serialize` / `mount_uploader` / custom-`attribute` column is a rich object at runtime, not its SQL
    # scalar. Its `ruby_type` is remapped to `"Object"` so instance-side narrowing declines — else
    # `note.position.diff_refs` (position stored `text`, deserialized to a Position) false-positives. The
    # column stays queryable, so `where(col: ...)` still validates existence.
    let(:override_schema) do
      <<~SCHEMA
        ActiveRecord::Schema.define do
          create_table :users do |t|
            t.string :name
            t.text   :prefs
            t.string :avatar
          end
        end
      SCHEMA
    end
    let(:override_models) do
      {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/user.rb" => <<~RUBY,
          class User < ApplicationRecord
            serialize :prefs
            mount_uploader :avatar, AvatarUploader
          end
        RUBY
        # A concern declares a serialize inside `included do` — the global-set collection must see it even
        # though the discoverer does not follow `include`.
        "app/models/concerns/positionable.rb" => <<~RUBY
          module Positionable
            extend ActiveSupport::Concern
            included do
              serialize :name, SomeCoder
            end
          end
        RUBY
      }
    end

    it "remaps serialize / mount_uploader / concern-serialized columns to Object, keeps scalars" do
      _result, index = run_ar_with_index("User.find(1)\n", models: override_models, schema: override_schema)
      user = index.find("User")
      expect(user.column("prefs").ruby_type).to eq("Object")  # serialize
      expect(user.column("avatar").ruby_type).to eq("Object") # mount_uploader
      expect(user.column("name").ruby_type).to eq("Object")   # concern `included do serialize :name`
    end

    it "keeps a normal column's schema type when nothing overrides it" do
      models = {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/user.rb" => "class User < ApplicationRecord\nend\n"
      }
      _result, index = run_ar_with_index("User.find(1)\n", models: models, schema: override_schema)
      expect(index.find("User").column("name").ruby_type).to eq("String")
    end

    it "still validates existence of a type-overridden column (`where(col:)`)" do
      # Overriding the value type must not remove the column — a real key passes, a typo still fires.
      diags = plugin_diagnostics(run_ar("User.where(prefs: 1)\n", models: override_models, schema: override_schema))
      expect(diags.find { |d| d.rule == "unknown-column" }).to be_nil
    end
  end

  describe "wrong-arity diagnostics" do
    it "errors when `find` is called with no arguments" do
      diags = plugin_diagnostics(run_ar("User.find\n"))
      err = diags.find { |d| d.rule == "wrong-arity" }
      expect(err.severity).to eq(:error)
      expect(err.message).to eq("`User.find` expects at least 1 argument, got 0")
    end
  end

  describe "non-model receivers" do
    it "stays silent when the receiver is not a known model" do
      diags = plugin_diagnostics(run_ar("Random.where(foo: 1)\n"))
      expect(diags).to be_empty
    end

    it "stays silent when the receiver is a local variable" do
      diags = plugin_diagnostics(run_ar("user = User.new; user.where(foo: 1)\n"))
      expect(diags).to be_empty
    end
  end

  describe "explicit `self.table_name` override" do
    let(:user_with_override) do
      DEFAULT_MODELS.merge("app/models/user.rb" => <<~RUBY)
        class User < ApplicationRecord
          self.table_name = "people"
        end
      RUBY
    end

    let(:schema_with_people_table) do
      <<~SCHEMA
        ActiveRecord::Schema[8.0].define(version: 1) do
          create_table "people", force: :cascade do |t|
            t.string "given_name"
            t.string "surname"
          end
        end
      SCHEMA
    end

    it "resolves the override, not the inflected name" do
      diags = plugin_diagnostics(
        run_ar("User.where(given_name: 'A')\n", models: user_with_override, schema: schema_with_people_table)
      )
      expect(diags.first.message).to eq("`User.where` (:given_name) on table `people`")
    end
  end

  describe "configurable model_base_classes" do
    let(:custom_base_models) do
      {
        "app/models/db_record.rb" => "class DbRecord\nend\n",
        "app/models/widget.rb" => "class Widget < DbRecord\nend\n"
      }
    end

    it "discovers models whose superclass matches the configured list" do
      schema = <<~SCHEMA
        ActiveRecord::Schema[8.0].define(version: 1) do
          create_table "widgets", force: :cascade do |t|
            t.string "label"
          end
        end
      SCHEMA

      diags = plugin_diagnostics(
        run_ar("Widget.where(label: 'x')\n",
               schema: schema,
               models: custom_base_models,
               plugin_config: { "model_base_classes" => ["DbRecord"] })
      )
      expect(diags.first.message).to eq("`Widget.where` (:label) on table `widgets`")
    end
  end

  describe "graceful failure modes" do
    it "discloses a missing `db/schema.rb` at :info rather than crashing" do
      # No `files:` argument — no schema.rb gets written. Shipping raw migrations only and gitignoring
      # `db/schema.rb` is a supported Rails layout, not a misconfiguration, and the plugin still types
      # models from source in that mode — so the disclosure is graded `:info` (what the plugin recognised),
      # not `:warning` (the plugin could not run). The two grades that DO stay `:warning` — an unreadable
      # and an unparseable schema — are pinned below.
      result = run_plugin(source: "User.find(1)\n")
      notice = result.diagnostics.find { |d| d.rule == "load-error" }
      expect(notice.severity).to eq(:info)
      expect(notice.message).to include("db/schema.rb")
      expect(notice.message).to include("not found")
      expect(notice.message).to include("column checks")
    end

    it "keeps an unreadable schema at :warning (the actionable half of the grade split)" do
      # The schema path EXISTS and the user meant it to be read, so failing to read it is a real problem
      # even though reduced mode still applies. Without this sibling the `:info` regrade above would read as
      # "every schema-load disclosure is informational". `db/schema.rb` as a directory is the deterministic
      # way to make the read raise something other than ENOENT (`Errno::EISDIR` from `File.binread`).
      Dir.mktmpdir do |dir|
        materialize_files(dir, DEFAULT_MODELS)
        FileUtils.mkdir_p(File.join(dir, "db", "schema.rb"))
        File.write(File.join(dir, "demo.rb"), "User.find(1)\n")
        Dir.chdir(dir) do
          configuration = Rigor::Configuration.new(
            "paths" => ["demo.rb"], "plugins" => ["rigor-activerecord"]
          )
          result = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil, collect_stats: false,
            plugin_requirer: build_plugin_requirer
          ).run
          notice = result.diagnostics.find { |d| d.rule == "load-error" }
          expect(notice).not_to be_nil
          expect(notice.severity).to eq(:warning)
        end
      end
    end

    it "emits the load-error disclosure at most once across many analyzed files" do
      # Solidus monorepo / Redmine (migrations-only) scale: hundreds of files, but `db/schema.rb` absence is a
      # single project-global root cause. Pre-fix the plugin emitted `load-error` per file (346× on Redmine).
      result = run_plugin(
        source: "User.find(1)\n",
        files: { "extra1.rb" => "stuff\n", "extra2.rb" => "more\n", "extra3.rb" => "again\n" }
      )
      load_errors = result.diagnostics.select { |d| d.rule == "load-error" }
      expect(load_errors.size).to eq(1)
    end

    it "attempts the missing-schema read only once across many AR call sites" do
      # Regression: `schema_table_or_nil` is invoked per AR call site via `model_index`; before memoizing the
      # *failure* it re-read the missing schema and appended a fresh interpolated error string to
      # `@load_errors` on every call, growing it without bound (measured: 4.2 M retained strings / ~1.5 GB on
      # Redmine). The internal error list must stay at one entry no matter how many call sites run.
      source = (1..40).map { |i| "User.where(id: #{i})\n" }.join
      Dir.mktmpdir do |dir|
        materialize_files(dir, { "demo.rb" => source }) # no db/schema.rb
        Dir.chdir(dir) do
          configuration = Rigor::Configuration.new(
            "paths" => ["demo.rb"], "plugins" => ["rigor-activerecord"]
          )
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil, collect_stats: false,
            plugin_requirer: build_plugin_requirer
          )
          runner.run
          plugin = runner.plugin_registry.find("activerecord")
          expect(plugin.instance_variable_get(:@load_errors).size).to eq(1)
        end
      end
    end
  end

  describe "reduced mode — no committed schema (#569)" do
    # A project that ships raw migrations and gitignores `db/schema.rb` (Redmine) used to get NOTHING from
    # this plugin: `model_index` short-circuited on the missing schema, so even `Project.find` — a call the
    # plugin fully models — stayed opaque. The schema gates the COLUMN surface only; table names, finders,
    # scopes and associations are all derived from project SOURCE. Reduced mode keeps those and lets the
    # column surface decline exactly as an unrecognised column already does.
    #
    # Every example below is paired with a schema-PRESENT sibling on the same fixture, so "the reduced mode
    # answers X" is always read against "the full mode answers Y".

    let(:reduced_models) do
      {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/user.rb" => <<~RUBY,
          class User < ApplicationRecord
            has_many :posts
            scope :admins, -> { where(admin: true) }
          end
        RUBY
        "app/models/post.rb" => <<~RUBY
          class Post < ApplicationRecord
            belongs_to :user
          end
        RUBY
      }
    end

    let(:reduced_schema) do
      <<~SCHEMA
        ActiveRecord::Schema[8.0].define(version: 2026_09_01_000000) do
          create_table "users", force: :cascade do |t|
            t.string  "name"
            t.boolean "admin"
          end

          create_table "posts", force: :cascade do |t|
            t.string "title"
            t.references "user", foreign_key: true
          end
        end
      SCHEMA
    end

    # The inferred type at a `Rigor.dump_type(...)` call, as the engine's own `dump-type` rule renders it.
    # This is the only channel that can tell `Dynamic` (what reduced mode used to produce everywhere) apart
    # from a real contributed type; a `call.undefined-method` probe would conflate `String` with `Constant`.
    def dumped_types(source, schema:)
      result = run_ar(source, schema: schema, models: reduced_models)
      result.diagnostics
            .select { |d| d.qualified_rule == "dump.type" }
            .map { |d| d.message.sub("dump_type: ", "") }
    end

    describe "must fire — the source-derived surface stays live without a schema" do
      it "types `Model.find(id)` as the model in both modes" do
        source = "Rigor.dump_type(User.find(1))\n"
        expect(dumped_types(source, schema: nil)).to eq(["User"])
        expect(dumped_types(source, schema: reduced_schema)).to eq(["User"])
      end

      it "types a declared `scope` call as the same relation in both modes" do
        source = "Rigor.dump_type(User.admins)\n"
        reduced = dumped_types(source, schema: nil)
        expect(reduced).to eq(dumped_types(source, schema: reduced_schema))
        expect(reduced.first).to include("User")
        expect(reduced.first).not_to include("untyped")
      end

      it "types a `has_many` association read as the same relation in both modes" do
        source = <<~RUBY
          user = User.find(1)
          Rigor.dump_type(user.posts)
        RUBY
        reduced = dumped_types(source, schema: nil)
        expect(reduced).to eq(dumped_types(source, schema: reduced_schema))
        expect(reduced.first).to include("Post")
      end

      it "types a `belongs_to` association read as the target model in both modes" do
        source = <<~RUBY
          post = Post.find(1)
          Rigor.dump_type(post.user)
        RUBY
        expect(dumped_types(source, schema: nil)).to eq(["User"])
        expect(dumped_types(source, schema: reduced_schema)).to eq(["User"])
      end

      it "still recognises the AR call itself (model-call info survives the missing schema)" do
        diags = plugin_diagnostics(run_ar("User.find(1)\n", schema: nil, models: reduced_models))
        info = diags.find { |d| d.rule == "model-call" }
        expect(info).not_to be_nil
        expect(info.message).to include("returns User (table: `users`)")
      end
    end

    describe "must decline — the column surface stands down exactly as an unknown column does" do
      it "leaves a column reader untyped without a schema, and types it with one" do
        source = <<~RUBY
          user = User.find(1)
          Rigor.dump_type(user.name)
        RUBY
        # `Dynamic[top]` means the plugin contributed nothing and the call fell back to the analyzer's own
        # dispatch — precisely what a column the schema does not declare already produces.
        expect(dumped_types(source, schema: nil)).to eq(["Dynamic[top]"])
        expect(dumped_types(source, schema: reduced_schema)).to eq(["String"])
      end

      it "does not fire unknown-column without a schema, and does fire with one" do
        typo = "User.where(emial: 'a')\n"
        reduced = plugin_diagnostics(run_ar(typo, schema: nil, models: reduced_models))
        full = plugin_diagnostics(run_ar(typo, schema: reduced_schema, models: reduced_models))
        expect(reduced.find { |d| d.rule == "unknown-column" }).to be_nil
        expect(full.find { |d| d.rule == "unknown-column" }).not_to be_nil
      end
    end

    describe "the index itself" do
      it "reports columns_known? false without a schema and true with one" do
        _result, reduced = run_ar_with_index("x = 1\n", models: reduced_models, schema: nil)
        _result, full = run_ar_with_index("x = 1\n", models: reduced_models, schema: reduced_schema)
        expect(reduced.columns_known?).to be(false)
        expect(full.columns_known?).to be(true)
      end

      it "keeps every source-derived field and empties only the columns" do
        _result, index = run_ar_with_index("x = 1\n", models: reduced_models, schema: nil)
        user = index.find("User")
        expect(user.table_name).to eq("users")
        expect(user.scopes).to eq(["admins"])
        expect(user.association_names).to eq(["posts"])
        expect(user.column_names).to be_empty
      end
    end

    describe "ADR-9 fact publication stays withheld in reduced mode" do
      # Every consumer reads `columns:` as authoritative: rigor-actionpack fires `unknown-permit-key` on a
      # `permit(:title)` key that is not in it, rigor-shoulda-matchers fires `unknown-column` on a
      # `have_db_column(:title)` matcher. Publishing the reduced index's EMPTY column set would turn this
      # precision win into a false positive on every strong-parameter key in the project, so the fact stays
      # unpublished — exactly where those consumers already are on a schema-less target.
      it "withholds the fact without a schema and publishes it with one" do
        expect(published_model_index(schema: nil)).to be_nil
        expect(published_model_index(schema: reduced_schema)).to include("User")
      end

      def published_model_index(schema:)
        published = :unset
        consumer = Class.new(Rigor::Plugin::Base) do
          manifest(
            id: "reduced-consumer", version: "0.1.0",
            consumes: [{ plugin_id: "activerecord", name: :model_index, optional: true }]
          )
        end
        consumer.define_method(:prepare) do |services|
          published = services.fact_store.read(plugin_id: "activerecord", name: :model_index)
        end
        stub_const("FakeReducedConsumerPlugin", consumer)
        run_with_consumer(consumer, schema: schema)
        published == :unset ? nil : published
      end

      def run_with_consumer(consumer, schema:)
        Rigor::Plugin.unregister!
        files = reduced_models.merge("demo.rb" => "x = 1\n")
        files["db/schema.rb"] = schema if schema
        Dir.mktmpdir do |dir|
          materialize_files(dir, files)
          Dir.chdir(dir) do
            configuration = Rigor::Configuration.new(
              Rigor::Configuration::DEFAULTS.merge(
                "paths" => ["demo.rb"],
                "plugins" => %w[rigor-activerecord rigor-reduced-consumer]
              )
            )
            Rigor::Analysis::Runner.new(
              configuration: configuration, cache_store: nil, collect_stats: false,
              plugin_requirer: lambda { |name|
                case File.basename(name, ".rb")
                when "rigor-activerecord" then Rigor::Plugin.register(Rigor::Plugin::Activerecord)
                when "rigor-reduced-consumer" then Rigor::Plugin.register(consumer)
                end
                true
              }
            ).run
          end
        end
      end
    end
  end

  describe "structure.sql fallback (schema_format = :sql)" do
    # GitLab-class apps commit a PostgreSQL `db/structure.sql` and no `db/schema.rb`, which used to leave
    # the plugin inert. The producer now falls back to parsing the DDL through StructureSqlParser.
    let(:structure_sql) { <<~SQL }
      CREATE TABLE users (
          id bigint NOT NULL,
          name character varying NOT NULL,
          email character varying NOT NULL,
          admin boolean DEFAULT false,
          role character varying DEFAULT '--- 0
      '::character varying NOT NULL,
          tag_ids bigint[],
          created_at timestamp without time zone,
          CONSTRAINT check_email CHECK ((email IS NOT NULL))
      );

      CREATE TABLE posts (
          id bigint NOT NULL,
          title character varying,
          body text,
          user_id bigint
      );

      CREATE TABLE gitlab_partitions_dynamic.users_part (
          id bigint NOT NULL,
          shadow character varying
      );
    SQL

    def run_structure(source, structure:, models: DEFAULT_MODELS)
      run_plugin(source: source, files: { "db/structure.sql" => structure }.merge(models))
    end

    it "recognises a `Model.where(col:)` call against structure.sql columns" do
      diags = plugin_diagnostics(run_structure("User.where(admin: true)\n", structure: structure_sql))
      expect(diags.find { |d| d.rule == "load-error" }).to be_nil
      expect(diags.map(&:message).join).to include("`User.where` (:admin) on table `users`")
    end

    it "fires unknown-column for a typo against structure.sql columns" do
      diags = plugin_diagnostics(run_structure("User.where(amdin: true)\n", structure: structure_sql))
      unknown = diags.find { |d| d.rule == "unknown-column" }
      expect(unknown).not_to be_nil
      expect(unknown.message).to include("amdin")
      expect(unknown.message).to include("did you mean `:admin`?")
    end

    it "parses a multi-line quoted default without inventing a bogus column" do
      # The `role` column's DEFAULT is a multi-line YAML string; the continuation line must not read as a
      # `'::character` column, and `role` itself must be a valid, recognised column.
      diags = plugin_diagnostics(run_structure("User.where(role: 'x')\n", structure: structure_sql))
      expect(diags.find { |d| d.rule == "unknown-column" }).to be_nil
    end

    it "skips partition tables in non-public schemas (no phantom `shadow` column masking)" do
      # `gitlab_partitions_dynamic.users_part` is a partition, not the base `users` table — its `shadow`
      # column must not leak onto any queryable model.
      diags = plugin_diagnostics(run_structure("User.where(shadow: 1)\n", structure: structure_sql))
      expect(diags.find { |d| d.rule == "unknown-column" }).not_to be_nil
    end

    it "prefers db/schema.rb when both files are present" do
      # schema.rb defines `admin`; a conflicting structure.sql must not be consulted when schema.rb loads.
      diags = plugin_diagnostics(
        run_plugin(
          source: "User.where(admin: true)\n",
          files: { "db/schema.rb" => DEFAULT_SCHEMA, "db/structure.sql" => "CREATE TABLE users (\n  id bigint\n);\n" }
            .merge(DEFAULT_MODELS)
        )
      )
      expect(diags.find { |d| d.rule == "load-error" }).to be_nil
      expect(diags.map(&:message).join).to include("`User.where` (:admin)")
    end
  end

  describe "dynamic_return / #dynamic_return_type return-type contribution (v0.1.2)" do
    # The plugin's `Model.find(id)` rule contributes `Nominal[Model]` so chained call sites resolve through the
    # analyzer's normal dispatch — without the contribution the RBS-level untyped return would let any chained
    # method name through silently. The `call.undefined-method` rule only fires when the receiver class is
    # known to RBS, so the tests below ship an RBS sig for User (top-level `USER_RBS_FOR_NARROWING`) declaring
    # its columns.
    def run_ar_with_user_sig(source, schema: DEFAULT_SCHEMA, models: DEFAULT_MODELS)
      files = { "db/schema.rb" => schema, "sig/user.rbs" => USER_RBS_FOR_NARROWING }.merge(models)
      run_plugin(
        source: source,
        plugin_entry: nil,
        files: files,
        signature_paths: ["sig"]
      )
    end

    it "narrows `Model.find(id)` to Nominal[Model] so non-Model calls surface" do
      result = run_ar_with_user_sig(<<~RUBY)
        user = User.find(1)
        user.bit_length
      RUBY
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("bit_length")
      end
      expect(undefined).not_to be_nil
      expect(undefined.message).to include("User")
    end

    it "narrows `Model.where` to a relation whose `.find` extracts the element" do
      # `where` → `ActiveRecord::Relation[User]`; `.find` → `User`, so a bad method on the extracted element
      # surfaces on `User`. (`bit_length` is NOT flagged on the relation itself — `ActiveRecord::Relation` is
      # an ADR-26 open receiver.)
      result = run_ar_with_user_sig(<<~RUBY)
        user = User.where(admin: true).find(1)
        user.bit_length
      RUBY
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("bit_length")
      end
      expect(undefined).not_to be_nil
      expect(undefined.message).to include("User")
    end

    it "does not contribute on non-model receivers" do
      result = run_ar_with_user_sig(<<~RUBY)
        x = Object.find(1)
        x.upcase
      RUBY
      # Object.find isn't a model — no contribution; the call falls through to the analyzer's normal dispatch.
      method_undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("upcase")
      end
      expect(method_undefined).to be_empty
    end
  end

  describe "associations (has_many / belongs_to / has_one) — v0.1.5" do
    # rigor-activerecord now records `has_many` / `belongs_to` / `has_one` declarations in the ModelIndex (and
    # contributes `Nominal[Target] | nil` for the singular cases via `dynamic_return`). The integration spec
    # asserts via the model-index lookup that the right rows landed; the singular return-type contribution is
    # covered via direct unit specs on the plugin classes (`spec/examples/activerecord/` — not bundled here).

    # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
    POST_USER_MODELS = {
      "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
      "app/models/user.rb" => <<~RUBY,
        class User < ApplicationRecord
          has_many :posts
          has_one :profile
        end
      RUBY
      "app/models/post.rb" => <<~RUBY,
        class Post < ApplicationRecord
          belongs_to :user
        end
      RUBY
      "app/models/profile.rb" => <<~RUBY
        class Profile < ApplicationRecord
          belongs_to :user
        end
      RUBY
    }.freeze

    POST_USER_PROFILE_SCHEMA = <<~SCHEMA
      ActiveRecord::Schema[8.0].define(version: 2026_05_15_000000) do
        create_table "users", force: :cascade do |t|
          t.string "name"
        end

        create_table "posts", force: :cascade do |t|
          t.string  "title"
          t.references "user", foreign_key: true
        end

        create_table "profiles", force: :cascade do |t|
          t.string "bio"
          t.references "user", foreign_key: true
        end
      end
    SCHEMA
    # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration

    def model_index_after_run(models:, schema: POST_USER_PROFILE_SCHEMA)
      files = { "db/schema.rb" => schema }.merge(models)
      Dir.mktmpdir do |dir|
        materialize_files(dir, files)
        materialize_files(dir, { "demo.rb" => "x = 1\n" })
        Dir.chdir(dir) do
          configuration = Rigor::Configuration.new(
            "paths" => ["demo.rb"],
            "plugins" => ["rigor-activerecord"]
          )
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil,
            collect_stats: false,
            plugin_requirer: build_plugin_requirer
          )
          runner.run
          runner.plugin_registry.find("activerecord").send(:model_index)
        end
      end
    end

    it "records `belongs_to :user` on Post as a singular association targeting User" do
      index = model_index_after_run(models: POST_USER_MODELS)
      post_entry = index.find("Post")

      expect(post_entry.associations).to contain_exactly(
        a_hash_including(name: "user", kind: :singular, target: "User", nullable: false)
      )
    end

    it "records `has_one :profile` on User as a singular association targeting Profile" do
      index = model_index_after_run(models: POST_USER_MODELS)
      user_entry = index.find("User")
      profile_association = user_entry.associations.find { |a| a[:name] == "profile" }

      expect(profile_association).to include(name: "profile", kind: :singular, target: "Profile",
                                             nullable: true)
    end

    it "records `has_many :posts` on User as a collection association" do
      index = model_index_after_run(models: POST_USER_MODELS)
      user_entry = index.find("User")
      posts_association = user_entry.associations.find { |a| a[:name] == "posts" }

      expect(posts_association).to include(name: "posts", kind: :collection, target: "Post")
    end

    it "respects an explicit `class_name:` option on belongs_to" do
      models = {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/post.rb" => <<~RUBY,
          class Post < ApplicationRecord
            belongs_to :author, class_name: "User"
          end
        RUBY
        "app/models/user.rb" => "class User < ApplicationRecord\nend\n"
      }
      index = model_index_after_run(models: models)
      post_entry = index.find("Post")
      author_association = post_entry.associations.find { |a| a[:name] == "author" }

      expect(author_association).to include(name: "author", kind: :singular, target: "User")
    end

    it "publishes a non-nullable `Nominal[Target]` for a required belongs_to" do
      # `belongs_to` is required (non-`nil`) by default since Rails 5, so `post.user` narrows to
      # `Nominal[User]` with no nil arm. Spec the return type directly on the plugin instance — Rigor's
      # diagnostic rule contract for chained calls is independent of the plugin's return-type publication.
      index = model_index_after_run(models: POST_USER_MODELS)
      runner_plugin = Rigor::Plugin::Activerecord.allocate
      runner_plugin.instance_variable_set(:@model_index, index)

      call_node = Prism.parse("post.user").value.statements.body.first
      double_scope = Object.new
      double_scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("Post")
      end
      double_scope.define_singleton_method(:environment) { nil }
      type = runner_plugin.dynamic_return_type(
        call_node: call_node, scope: double_scope,
        receiver_type: Rigor::Type::Combinator.untyped
      )

      expect(type).to eq(Rigor::Type::Combinator.nominal_of("User"))
    end

    it "publishes a nullable `Nominal[Target] | nil` for has_one" do
      # `has_one` genuinely returns `nil` when no associated record exists, so `user.profile` keeps the nil arm.
      index = model_index_after_run(models: POST_USER_MODELS)
      runner_plugin = Rigor::Plugin::Activerecord.allocate
      runner_plugin.instance_variable_set(:@model_index, index)

      call_node = Prism.parse("user.profile").value.statements.body.first
      double_scope = Object.new
      double_scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("User")
      end
      double_scope.define_singleton_method(:environment) { nil }
      type = runner_plugin.dynamic_return_type(
        call_node: call_node, scope: double_scope,
        receiver_type: Rigor::Type::Combinator.untyped
      )

      expect(type).to eq(
        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.nominal_of("Profile"),
          Rigor::Type::Combinator.constant_of(nil)
        )
      )
    end

    it "publishes a nullable type for `belongs_to ..., optional: true`" do # rubocop:disable RSpec/ExampleLength
      models = {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/post.rb" => <<~RUBY,
          class Post < ApplicationRecord
            belongs_to :user, optional: true
          end
        RUBY
        "app/models/user.rb" => "class User < ApplicationRecord\nend\n"
      }
      index = model_index_after_run(models: models)
      runner_plugin = Rigor::Plugin::Activerecord.allocate
      runner_plugin.instance_variable_set(:@model_index, index)

      call_node = Prism.parse("post.user").value.statements.body.first
      double_scope = Object.new
      double_scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("Post")
      end
      double_scope.define_singleton_method(:environment) { nil }
      type = runner_plugin.dynamic_return_type(
        call_node: call_node, scope: double_scope,
        receiver_type: Rigor::Type::Combinator.untyped
      )

      expect(type).to eq(
        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.nominal_of("User"),
          Rigor::Type::Combinator.constant_of(nil)
        )
      )
    end

    it "contributes `ActiveRecord::Relation[Target]` on a has_many call" do
      index = model_index_after_run(models: POST_USER_MODELS)
      runner_plugin = Rigor::Plugin::Activerecord.allocate
      runner_plugin.instance_variable_set(:@model_index, index)

      call_node = Prism.parse("user.posts").value.statements.body.first
      double_scope = Object.new
      double_scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("User")
      end
      double_scope.define_singleton_method(:environment) { nil }
      type = runner_plugin.dynamic_return_type(
        call_node: call_node, scope: double_scope,
        receiver_type: Rigor::Type::Combinator.untyped
      )

      expect(type).to eq(
        Rigor::Type::Combinator.nominal_of(
          "ActiveRecord::Relation",
          type_args: [Rigor::Type::Combinator.nominal_of("Post")]
        )
      )
    end

    it "accepts a singular association name as a `find_by` / `where` key alias" do
      # Mastodon-derived regression: `AccountPin.find_by(account: x)` passes the belongs_to association name
      # `:account` instead of the FK column `:account_id`. ActiveRecord accepts both; the plugin should match.
      # Pre-fix this was 100+ FPs on Mastodon's API controllers.
      result = run_plugin(
        source: "Post.find_by(user: x); Post.where(user: y)\n",
        files: {
          "db/schema.rb" => POST_USER_PROFILE_SCHEMA,
          **POST_USER_MODELS
        }
      )
      diags = plugin_diagnostics(result)
      expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
    end

    it "still flags an unknown key that is neither column nor singular association" do
      result = run_plugin(
        source: "Post.find_by(posts: x)\n",
        files: {
          "db/schema.rb" => POST_USER_PROFILE_SCHEMA,
          **POST_USER_MODELS
        }
      )
      diags = plugin_diagnostics(result)
      # `posts` would be a has_many (collection) association on a hypothetical reverse relationship; it's not
      # declared here at all, so the plugin should still error.
      expect(diags.find { |d| d.rule == "unknown-column" && d.message.include?("`posts`") }).not_to be_nil
    end
  end

  describe "enums — v0.1.5" do
    # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
    ENUM_SCHEMA = <<~SCHEMA
      ActiveRecord::Schema[8.0].define do
        create_table "posts", force: :cascade do |t|
          t.string "title"
          t.integer "status", default: 0
        end
      end
    SCHEMA

    ENUM_MODELS_HASH_FORM = {
      "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
      "app/models/post.rb" => <<~RUBY
        class Post < ApplicationRecord
          enum status: { active: 0, archived: 1 }
        end
      RUBY
    }.freeze

    ENUM_MODELS_RAILS7_FORM = {
      "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
      "app/models/post.rb" => <<~RUBY
        class Post < ApplicationRecord
          enum :status, [:active, :archived]
        end
      RUBY
    }.freeze
    # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration

    it "records the enum values from the Rails ≤6 hash form" do
      _result, index = run_ar_with_index("x = 1\n", models: ENUM_MODELS_HASH_FORM, schema: ENUM_SCHEMA)
      expect(index.find("Post").enums).to eq("status" => %w[active archived])
    end

    it "records the enum values from the Rails 7+ positional form" do
      _result, index = run_ar_with_index("x = 1\n", models: ENUM_MODELS_RAILS7_FORM, schema: ENUM_SCHEMA)
      expect(index.find("Post").enums).to eq("status" => %w[active archived])
    end

    it "flags `Model.where(status: :unknown)` when the value is not a declared enum value" do
      result, _index = run_ar_with_index("Post.where(status: :draft)\n",
                                         models: ENUM_MODELS_HASH_FORM, schema: ENUM_SCHEMA)
      diag = result.diagnostics.find { |d| d.rule == "unknown-enum-value" }
      expect(diag).not_to be_nil
      expect(diag.message).to include(":draft")
      expect(diag.message).to include("active")
      expect(diag.message).to include("archived")
    end

    it "stays silent on `Model.where(status: known_value)` when the value matches a declared enum" do
      result, _index = run_ar_with_index("Post.where(status: :active)\n",
                                         models: ENUM_MODELS_HASH_FORM, schema: ENUM_SCHEMA)
      diag = result.diagnostics.find { |d| d.rule == "unknown-enum-value" }
      expect(diag).to be_nil
    end

    it "declines (no diagnostic) when the enum value is a non-Symbol expression" do
      result, _index = run_ar_with_index("Post.where(status: user_supplied_status)\n",
                                         models: ENUM_MODELS_HASH_FORM, schema: ENUM_SCHEMA)
      diag = result.diagnostics.find { |d| d.rule == "unknown-enum-value" }
      expect(diag).to be_nil
    end
  end

  describe "scopes — v0.1.5" do
    # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
    SCOPE_MODELS = {
      "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
      "app/models/post.rb" => <<~RUBY
        class Post < ApplicationRecord
          scope :published, -> { where(published: true) }
          scope :recent, -> { order(created_at: :desc) }
        end
      RUBY
    }.freeze

    SCOPE_SCHEMA = <<~SCHEMA
      ActiveRecord::Schema[8.0].define do
        create_table "posts", force: :cascade do |t|
          t.string "title"
          t.boolean "published"
        end
      end
    SCHEMA
    # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration

    it "records the declared scope names on the model entry" do
      _result, index = run_ar_with_index("x = 1\n", models: SCOPE_MODELS, schema: SCOPE_SCHEMA)
      entry = index.find("Post")

      expect(entry.scopes).to contain_exactly("published", "recent")
      expect(entry.scope?("published")).to be(true)
      expect(entry.scope?("nonexistent")).to be(false)
    end

    it "types an implicit-self `select(...)` inside a scope lambda as Relation[Model]" do
      # The lambda body's `self_type` is `Singleton[Post]`, so `select(:title).group(:title)` opens a relation
      # via the AR plugin instead of falling through to `Kernel#select`'s IO-multiplexer return (`Array[String]`).
      source = <<~RUBY
        Post.published.merge(Post.where(title: 'x'))
      RUBY
      result = run_ar(source, models: SCOPE_MODELS, schema: SCOPE_SCHEMA)
      undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method"
      end
      expect(undefined).to be_empty
    end

    it "contributes Relation[Model] for an implicit-self class-side call" do
      _result, index = run_ar_with_index("x = 1\n", models: SCOPE_MODELS, schema: SCOPE_SCHEMA)
      plugin = Rigor::Plugin::Activerecord.allocate
      plugin.instance_variable_set(:@model_index, index)
      call_node = Prism.parse("select(:title).group(:title)").value.statements.body.first.receiver
      scope = Object.new
      scope.define_singleton_method(:self_type) { Rigor::Type::Combinator.singleton_of("Post") }
      scope.define_singleton_method(:environment) { nil }
      type = plugin.dynamic_return_type(
        call_node: call_node, scope: scope,
        receiver_type: Rigor::Type::Combinator.untyped
      )
      expect(type).to eq(
        Rigor::Type::Combinator.nominal_of(
          "ActiveRecord::Relation",
          type_args: [Rigor::Type::Combinator.nominal_of("Post")]
        )
      )
    end

    it "declines an implicit-self call when the surrounding self_type is not a known model" do
      _result, index = run_ar_with_index("x = 1\n", models: SCOPE_MODELS, schema: SCOPE_SCHEMA)
      plugin = Rigor::Plugin::Activerecord.allocate
      plugin.instance_variable_set(:@model_index, index)
      call_node = Prism.parse("select(:title)").value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:self_type) { Rigor::Type::Combinator.singleton_of("RandomClass") }
      scope.define_singleton_method(:environment) { nil }
      expect(
        plugin.dynamic_return_type(
          call_node: call_node, scope: scope,
          receiver_type: Rigor::Type::Combinator.untyped
        )
      ).to be_nil
    end
  end

  describe "validations + callbacks — v0.1.5" do
    # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
    VAL_CB_SCHEMA = <<~SCHEMA
      ActiveRecord::Schema[8.0].define do
        create_table "posts", force: :cascade do |t|
          t.string "title"
          t.text   "body"
        end
      end
    SCHEMA

    VAL_CB_MODELS = {
      "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
      "app/models/post.rb" => <<~RUBY
        class Post < ApplicationRecord
          validates :title, presence: true
          validates_length_of :body, maximum: 1000

          before_save :normalize_title
          after_create :send_notification

          def normalize_title
            self.title = title.to_s.strip
          end
        end
      RUBY
    }.freeze
    # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration

    it "records the validated attributes" do
      _result, index = run_ar_with_index("x = 1\n", models: VAL_CB_MODELS, schema: VAL_CB_SCHEMA)
      entry = index.find("Post")

      expect(entry.validated_attributes).to contain_exactly("title", "body")
      expect(entry.validation?("title")).to be(true)
      expect(entry.validation?("missing")).to be(false)
    end

    it "records the callback target method names" do
      _result, index = run_ar_with_index("x = 1\n", models: VAL_CB_MODELS, schema: VAL_CB_SCHEMA)
      entry = index.find("Post")

      expect(entry.callback_targets).to contain_exactly("normalize_title", "send_notification")
    end
  end

  describe "ADR-9 :model_index publication" do
    # Loads rigor-activerecord (the producer) alongside a synthetic consumer plugin that reads the published
    # :model_index in its `prepare(services)` hook and emits a diagnostic naming the column set it sees. This
    # is the same shape rigor-actionpack Phase 1 / rigor-factorybot Phase 1 (c) will use; the test pins the
    # publication contract.
    let(:consumer_plugin) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(
          id: "model-consumer", version: "0.1.0",
          consumes: [{ plugin_id: "activerecord", name: :model_index, optional: true }]
        )

        def prepare(services)
          @published = services.fact_store.read(plugin_id: "activerecord", name: :model_index)
        end

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          return [] if @published.nil?

          summary = @published.map { |klass_name, h| "#{klass_name}=#{h[:columns].join(',')}" }.join("|")
          [Rigor::Analysis::Diagnostic.new(
            path: path, line: 1, column: 1,
            message: "model_index seen: #{summary}",
            severity: :info, rule: "saw-model-index"
          )]
        end
      end
      stub_const("FakeModelConsumerPlugin", klass)
      klass
    end

    def run_two_plugins(source, schema:, models:)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "db", "schema.rb"), schema)
        models.each do |relative, contents|
          full = File.join(dir, relative)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, contents)
        end
        File.write(File.join(dir, "demo.rb"), source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => %w[rigor-activerecord rigor-model-consumer]
          )
        )
        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil,
            plugin_requirer: lambda { |name|
              # #194 slice 2 — a bundled plugin now arrives as its engine-anchored absolute path; basename
              # recovers the gem name (a bare name, e.g. the non-bundled `rigor-model-consumer`, passes
              # through unchanged).
              case File.basename(name, ".rb")
              when "rigor-activerecord" then Rigor::Plugin.register(Rigor::Plugin::Activerecord)
              when "rigor-model-consumer" then Rigor::Plugin.register(consumer_plugin)
              end
              true
            }
          )
          yield runner.run
        end
      end
    end

    it "publishes the model index for downstream consumers via services.fact_store" do
      run_two_plugins(
        "x = 1\n",
        schema: DEFAULT_SCHEMA,
        models: DEFAULT_MODELS
      ) do |result|
        info = result.diagnostics.find { |d| d.rule == "saw-model-index" }
        expect(info).not_to be_nil
        expect(info.message).to include("User=")
        # Default schema declares User columns (id, name, email).
        expect(info.message).to include("name")
        expect(info.message).to include("email")
      end
    end
  end

  describe "polymorphic `t.references` — `_type` column" do
    let(:poly_schema) do
      <<~SCHEMA
        ActiveRecord::Schema[8.0].define do
          create_table "comments", force: :cascade do |t|
            t.text "body"
            t.references "commentable", polymorphic: true
          end
        end
      SCHEMA
    end

    let(:poly_models) do
      {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/comment.rb" => "class Comment < ApplicationRecord\nend\n"
      }
    end

    it "adds `<name>_type` alongside `<name>_id` for a polymorphic reference" do
      diags = plugin_diagnostics(
        run_ar("Comment.where(commentable_type: 'Post', commentable_id: 1)\n",
               schema: poly_schema, models: poly_models)
      )
      expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
    end

    it "adds only `<name>_id` for a non-polymorphic reference" do
      # DEFAULT_SCHEMA's `posts` table has a plain `t.references "user"` — no `user_type` column exists.
      diags = plugin_diagnostics(run_ar("Post.where(user_type: 'x')\n"))
      expect(diags.find { |d| d.rule == "unknown-column" && d.message.include?("user_type") }).not_to be_nil
    end
  end

  describe "exotic / generic column types are not dropped" do
    let(:exotic_schema) do
      <<~SCHEMA
        ActiveRecord::Schema[8.0].define do
          create_table "accounts", force: :cascade do |t|
            t.citext "email"
            t.uuid   "public_token"
            t.inet   "last_ip"
            t.column "preferences", :jsonb
            t.index  ["email"], unique: true
          end
        end
      SCHEMA
    end

    let(:exotic_models) do
      {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/account.rb" => "class Account < ApplicationRecord\nend\n"
      }
    end

    it "recognises citext / uuid / inet / generic-column declarations as columns" do
      diags = plugin_diagnostics(
        run_ar("Account.where(email: 'a', public_token: 't', last_ip: '127.0.0.1', preferences: {})\n",
               schema: exotic_schema, models: exotic_models)
      )
      expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
    end

    it "does not treat a structural `t.index` declaration as a column" do
      diags = plugin_diagnostics(
        run_ar("Account.where(nonexistent: 1)\n", schema: exotic_schema, models: exotic_models)
      )
      expect(diags.find { |d| d.rule == "unknown-column" }).not_to be_nil
    end
  end

  describe "alias_attribute query keys" do
    let(:alias_models) do
      {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/user.rb" => <<~RUBY,
          class User < ApplicationRecord
            alias_attribute :email_address, :email
          end
        RUBY
        "app/models/post.rb" => "class Post < ApplicationRecord\nend\n"
      }
    end

    it "accepts an aliased attribute as a `where` / `find_by` key" do
      diags = plugin_diagnostics(
        run_ar("User.where(email_address: 'a'); User.find_by(email_address: 'b')\n", models: alias_models)
      )
      expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
    end

    it "records the alias on the model entry" do
      _result, index = run_ar_with_index("x = 1\n", models: alias_models, schema: DEFAULT_SCHEMA)
      entry = index.find("User")

      expect(entry.alias?("email_address")).to be(true)
      expect(entry.resolve_alias("email_address")).to eq("email")
    end

    it "still flags a genuine typo that is not an alias" do
      diags = plugin_diagnostics(run_ar("User.where(emial: 'a')\n", models: alias_models))
      expect(diags.find { |d| d.rule == "unknown-column" }).not_to be_nil
    end
  end

  describe "association coverage — HABTM / polymorphic / composed_of / delegated_type" do
    def dynamic_return_type_for_call(index:, source:, receiver_class:)
      plugin = Rigor::Plugin::Activerecord.allocate
      plugin.instance_variable_set(:@model_index, index)
      call_node = Prism.parse(source).value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of(receiver_class)
      end
      scope.define_singleton_method(:environment) { nil }
      plugin.dynamic_return_type(
        call_node: call_node, scope: scope,
        receiver_type: Rigor::Type::Combinator.untyped
      )
    end

    it "records `has_and_belongs_to_many` as a collection association" do
      models = {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/post.rb" => <<~RUBY
          class Post < ApplicationRecord
            has_and_belongs_to_many :tags
          end
        RUBY
      }
      _result, index = run_ar_with_index("x = 1\n", models: models, schema: DEFAULT_SCHEMA)
      tags = index.find("Post").associations.find { |a| a[:name] == "tags" }

      expect(tags).to include(name: "tags", kind: :collection, target: "Tag")
    end

    context "with a polymorphic `belongs_to`" do
      let(:poly_models) do
        {
          "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
          "app/models/comment.rb" => <<~RUBY
            class Comment < ApplicationRecord
              belongs_to :commentable, polymorphic: true
            end
          RUBY
        }
      end

      let(:poly_schema) do
        <<~SCHEMA
          ActiveRecord::Schema[8.0].define do
            create_table "comments", force: :cascade do |t|
              t.text "body"
              t.references "commentable", polymorphic: true
            end
          end
        SCHEMA
      end

      it "records it as a singular association with a nil target" do
        _result, index = run_ar_with_index("x = 1\n", models: poly_models, schema: poly_schema)
        assoc = index.find("Comment").associations.find { |a| a[:name] == "commentable" }

        expect(assoc).to include(name: "commentable", kind: :singular, target: nil, polymorphic: true)
      end

      it "accepts the polymorphic association name as a query key" do
        diags = plugin_diagnostics(
          run_ar("Comment.where(commentable: x)\n", schema: poly_schema, models: poly_models)
        )
        expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
      end

      it "declines to contribute a (wrong) Nominal type for the polymorphic accessor" do
        _result, index = run_ar_with_index("x = 1\n", models: poly_models, schema: poly_schema)
        type = dynamic_return_type_for_call(
          index: index, source: "comment.commentable", receiver_class: "Comment"
        )
        expect(type).to be_nil
      end
    end

    context "with a `composed_of` aggregation" do
      let(:composed_models) do
        {
          "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
          "app/models/account.rb" => <<~RUBY
            class Account < ApplicationRecord
              composed_of :balance, class_name: "Money"
            end
          RUBY
        }
      end

      let(:composed_schema) do
        <<~SCHEMA
          ActiveRecord::Schema[8.0].define do
            create_table "accounts", force: :cascade do |t|
              t.integer "balance_amount"
              t.string  "balance_currency"
            end
          end
        SCHEMA
      end

      it "records it as a singular association targeting its value class" do
        _result, index = run_ar_with_index("x = 1\n", models: composed_models, schema: composed_schema)
        assoc = index.find("Account").associations.find { |a| a[:name] == "balance" }

        expect(assoc).to include(name: "balance", kind: :singular, target: "Money", nullable: false)
      end

      it "accepts the aggregation name as a query key" do
        diags = plugin_diagnostics(
          run_ar("Account.where(balance: m)\n", schema: composed_schema, models: composed_models)
        )
        expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
      end

      it "contributes `Nominal[ValueClass]` for the aggregation accessor" do
        _result, index = run_ar_with_index("x = 1\n", models: composed_models, schema: composed_schema)
        type = dynamic_return_type_for_call(
          index: index, source: "account.balance", receiver_class: "Account"
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Money"))
      end
    end

    it "records `delegated_type` as a polymorphic singular association" do
      models = {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/entry.rb" => <<~RUBY
          class Entry < ApplicationRecord
            delegated_type :entryable, types: %w[Message Comment]
          end
        RUBY
      }
      schema = <<~SCHEMA
        ActiveRecord::Schema[8.0].define do
          create_table "entries", force: :cascade do |t|
            t.references "entryable", polymorphic: true
          end
        end
      SCHEMA
      _result, index = run_ar_with_index("x = 1\n", models: models, schema: schema)
      assoc = index.find("Entry").associations.find { |a| a[:name] == "entryable" }

      expect(assoc).to include(name: "entryable", kind: :singular, target: nil, polymorphic: true)
    end
  end

  describe "single-table inheritance (STI)" do
    let(:sti_models) do
      {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/user.rb" => <<~RUBY,
          class User < ApplicationRecord
            belongs_to :company
            alias_attribute :email_address, :email
          end
        RUBY
        "app/models/admin.rb" => "class Admin < User\nend\n",
        "app/models/super_admin.rb" => "class SuperAdmin < Admin\nend\n",
        "app/models/plain_object.rb" => "class PlainObject\nend\n",
        "app/models/post.rb" => "class Post < ApplicationRecord\nend\n"
      }
    end

    it "discovers an STI subclass and resolves its table to the root model's" do
      _result, index = run_ar_with_index("x = 1\n", models: sti_models, schema: DEFAULT_SCHEMA)

      expect(index.model?("Admin")).to be(true)
      expect(index.find("Admin").table_name).to eq("users")
    end

    it "discovers a multi-level STI subclass" do
      _result, index = run_ar_with_index("x = 1\n", models: sti_models, schema: DEFAULT_SCHEMA)

      expect(index.find("SuperAdmin").table_name).to eq("users")
    end

    it "does not treat a plain non-AR class as a model" do
      _result, index = run_ar_with_index("x = 1\n", models: sti_models, schema: DEFAULT_SCHEMA)

      expect(index.model?("PlainObject")).to be(false)
    end

    it "validates a column query on the STI subclass against the inherited table" do
      diags = plugin_diagnostics(run_ar("Admin.where(email: 'a')\n", models: sti_models))
      expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
    end

    it "still flags a genuine typo on the STI subclass" do
      diags = plugin_diagnostics(run_ar("Admin.where(emial: 'a')\n", models: sti_models))
      expect(diags.find { |d| d.rule == "unknown-column" }).not_to be_nil
    end

    it "inherits the parent model's associations on the STI subclass" do
      # `belongs_to :company` is declared on User; the child must accept `:company` as a query key or it is a
      # false positive.
      diags = plugin_diagnostics(run_ar("Admin.find_by(company: x)\n", models: sti_models))
      expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
    end

    it "inherits the parent model's alias_attribute mappings" do
      diags = plugin_diagnostics(run_ar("Admin.where(email_address: 'a')\n", models: sti_models))
      expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
    end

    it "narrows `STISubclass.find(id)` to the subclass type" do
      result = run_plugin(
        source: "admin = Admin.find(1)\nadmin.bit_length\n",
        files: {
          "db/schema.rb" => DEFAULT_SCHEMA,
          "sig/user.rbs" => "class Admin\n  attr_accessor email: String\nend\n",
          **sti_models
        },
        signature_paths: ["sig"]
      )
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("bit_length")
      end
      expect(undefined).not_to be_nil
      expect(undefined.message).to include("Admin")
    end
  end

  describe "bang / create-or-find finder variants" do
    it "validates column keys on `find_by!`" do
      diags = plugin_diagnostics(run_ar("User.find_by!(emial: 'a')\n"))
      expect(diags.find { |d| d.rule == "unknown-column" }).not_to be_nil
    end

    it "validates column keys on `create_or_find_by`" do
      diags = plugin_diagnostics(run_ar("User.create_or_find_by(emial: 'a')\n"))
      expect(diags.find { |d| d.rule == "unknown-column" }).not_to be_nil
    end

    it "stays silent on a valid key for `find_or_create_by!`" do
      diags = plugin_diagnostics(run_ar("User.find_or_create_by!(email: 'a')\n"))
      expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
    end

    it "narrows `find_by!` to a non-nullable model type" do
      result = run_plugin(
        source: "u = User.find_by!(email: 'a')\nu.bit_length\n",
        files: {
          "db/schema.rb" => DEFAULT_SCHEMA,
          "sig/user.rbs" => USER_RBS_FOR_NARROWING,
          **DEFAULT_MODELS
        },
        signature_paths: ["sig"]
      )
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("bit_length")
      end
      expect(undefined).not_to be_nil
    end
  end

  describe "instance column accessors" do
    def column_contribution(index:, source:, receiver_class:)
      plugin = Rigor::Plugin::Activerecord.allocate
      plugin.instance_variable_set(:@model_index, index)
      call_node = Prism.parse(source).value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of(receiver_class)
      end
      scope.define_singleton_method(:environment) { nil }
      plugin.dynamic_return_type(
        call_node: call_node, scope: scope,
        receiver_type: Rigor::Type::Combinator.untyped
      )
    end

    let(:bool_union) do
      Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(true),
        Rigor::Type::Combinator.constant_of(false)
      )
    end

    it "contributes the column value type for a string accessor" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      type = column_contribution(index: index, source: "user.name", receiver_class: "User")

      expect(type).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "contributes Integer for the implicit `id` column" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      type = column_contribution(index: index, source: "user.id", receiver_class: "User")

      expect(type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "contributes `bool` for a boolean column accessor" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      type = column_contribution(index: index, source: "user.admin", receiver_class: "User")

      expect(type).to eq(bool_union)
    end

    it "contributes `bool` for the generated `<column>?` predicate" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      type = column_contribution(index: index, source: "user.name?", receiver_class: "User")

      expect(type).to eq(bool_union)
    end

    it "declines for a json / jsonb (`Object`-typed) column" do
      models = {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/account.rb" => "class Account < ApplicationRecord\nend\n"
      }
      schema = <<~SCHEMA
        ActiveRecord::Schema[8.0].define do
          create_table "accounts", force: :cascade do |t|
            t.jsonb "preferences"
          end
        end
      SCHEMA
      _result, index = run_ar_with_index("x = 1\n", models: models, schema: schema)
      type = column_contribution(index: index, source: "account.preferences", receiver_class: "Account")

      expect(type).to be_nil
    end

    it "declines for a method that is neither a column nor an association" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      type = column_contribution(index: index, source: "user.totally_unknown", receiver_class: "User")

      expect(type).to be_nil
    end

    it "types an accessor end-to-end so a chained typo on the column surfaces" do
      result = run_ar("u = User.find(1)\nu.name.bit_length\n")
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("bit_length")
      end
      expect(undefined).not_to be_nil
      expect(undefined.message).to include("String")
    end

    it "stays silent on a valid method of the column's value type" do
      result = run_ar("u = User.find(1)\nu.name.upcase\n")
      undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("upcase")
      end
      expect(undefined).to be_empty
    end

    describe "Postgres array columns (`t.<type> ..., array: true`)" do
      let(:array_schema) do
        <<~SCHEMA
          ActiveRecord::Schema[8.0].define do
            create_table "reports", force: :cascade do |t|
              t.bigint "status_ids", default: [], null: false, array: true
              t.string "tag_names", array: true
              t.column "preferences", :string, array: true
            end
          end
        SCHEMA
      end

      let(:array_models) do
        {
          "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
          "app/models/report.rb" => "class Report < ApplicationRecord\nend\n"
        }
      end

      it "wraps a `t.bigint ..., array: true` accessor in Array[Integer]" do
        _result, index = run_ar_with_index("x = 1\n", models: array_models, schema: array_schema)
        type = column_contribution(index: index, source: "report.status_ids", receiver_class: "Report")
        expect(type).to eq(
          Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("Integer")])
        )
      end

      it "wraps a `t.string ..., array: true` accessor in Array[String]" do
        _result, index = run_ar_with_index("x = 1\n", models: array_models, schema: array_schema)
        type = column_contribution(index: index, source: "report.tag_names", receiver_class: "Report")
        expect(type).to eq(
          Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")])
        )
      end

      it "wraps a `t.column ..., array: true` accessor in Array[<inner>]" do
        _result, index = run_ar_with_index("x = 1\n", models: array_models, schema: array_schema)
        type = column_contribution(index: index, source: "report.preferences", receiver_class: "Report")
        expect(type).to eq(
          Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")])
        )
      end

      it "lets an array-column accessor chain through Array#uniq without false-firing call.undefined-method" do
        source = <<~RUBY
          r = Report.find(1)
          (r.status_ids + [1, 2]).uniq
        RUBY
        result = run_ar(source, models: array_models, schema: array_schema)
        undefined = result.diagnostics.select do |d|
          d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("uniq")
        end
        expect(undefined).to be_empty
      end
    end
  end

  describe "declarations inside a `with_options` block" do
    let(:with_options_models) do
      {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/report.rb" => <<~RUBY,
          class Report < ApplicationRecord
            with_options class_name: "Account" do
              belongs_to :target_account
              belongs_to :assigned_account, optional: true
            end
          end
        RUBY
        "app/models/account.rb" => "class Account < ApplicationRecord\nend\n"
      }
    end

    let(:reports_schema) do
      <<~SCHEMA
        ActiveRecord::Schema[8.0].define do
          create_table "reports", force: :cascade do |t|
            t.bigint "target_account_id"
            t.bigint "assigned_account_id"
          end

          create_table "accounts", force: :cascade do |t|
            t.string "username"
          end
        end
      SCHEMA
    end

    it "discovers a `belongs_to` nested inside `with_options`" do
      _result, index = run_ar_with_index("x = 1\n", models: with_options_models, schema: reports_schema)
      report = index.find("Report")

      expect(report.association?("target_account")).to be(true)
      expect(report.association?("assigned_account")).to be(true)
    end

    it "accepts the nested association name as a query key" do
      # Mastodon-derived regression: `Report` declares its account belongs_to associations inside a
      # `with_options class_name: 'Account'` block. Before the `with_options` descent every
      # `Report.where(target_account: ...)` surfaced as a false `unknown-column`.
      diags = plugin_diagnostics(
        run_ar("Report.where(target_account: a)\n", models: with_options_models, schema: reports_schema)
      )
      expect(diags.select { |d| d.rule == "unknown-column" }).to be_empty
    end
  end

  describe "ActiveRecord::Relation typing (ADR-26)" do
    def relation_type(model)
      Rigor::Type::Combinator.nominal_of(
        "ActiveRecord::Relation",
        type_args: [Rigor::Type::Combinator.nominal_of(model)]
      )
    end

    def relation_contribution(index:, source:, receiver_class:)
      plugin = Rigor::Plugin::Activerecord.allocate
      plugin.instance_variable_set(:@model_index, index)
      call_node = Prism.parse(source).value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of(receiver_class)
      end
      scope.define_singleton_method(:environment) { nil }
      plugin.dynamic_return_type(
        call_node: call_node, scope: scope,
        receiver_type: Rigor::Type::Combinator.untyped
      )
    end

    let(:scope_models) do
      {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/post.rb" => <<~RUBY
          class Post < ApplicationRecord
            scope :published, -> { where(published: true) }
            has_and_belongs_to_many :tags
          end
        RUBY
      }
    end

    let(:scope_schema) do
      <<~SCHEMA
        ActiveRecord::Schema[8.0].define do
          create_table "posts", force: :cascade do |t|
            t.boolean "published"
          end
        end
      SCHEMA
    end

    it "declares the bundled relation RBS and the open receiver in the manifest" do
      expect(plugin_class.manifest.signature_paths).to eq(["sig"])
      expect(plugin_class.manifest.open_receivers).to eq(["ActiveRecord::Relation"])
    end

    it "contributes `ActiveRecord::Relation[Model]` for `Model.where`" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      type = relation_contribution(index: index, source: "User.where(admin: true)", receiver_class: "User")

      expect(type).to eq(relation_type("User"))
    end

    it "contributes a relation for a user-declared `scope`" do
      _result, index = run_ar_with_index("x = 1\n", models: scope_models, schema: scope_schema)
      type = relation_contribution(index: index, source: "Post.published", receiver_class: "Post")

      expect(type).to eq(relation_type("Post"))
    end

    it "contributes a relation for a `has_and_belongs_to_many` accessor" do
      _result, index = run_ar_with_index("x = 1\n", models: scope_models, schema: scope_schema)
      type = relation_contribution(index: index, source: "post.tags", receiver_class: "Post")

      expect(type).to eq(relation_type("Tag"))
    end

    it "re-contributes the relation type for a scope invoked ON a relation" do
      # `Post.where(...).published` — the receiver of `.published` is `ActiveRecord::Relation[Post]`; the
      # scope keeps the element type through the chain.
      _result, index = run_ar_with_index("x = 1\n", models: scope_models, schema: scope_schema)
      plugin = Rigor::Plugin::Activerecord.allocate
      plugin.instance_variable_set(:@model_index, index)
      call_node = Prism.parse("rel.published").value.statements.body.first
      post_relation = relation_type("Post")
      scope = Object.new
      scope.define_singleton_method(:type_of) { |_node| post_relation }
      scope.define_singleton_method(:environment) { nil }
      type = plugin.dynamic_return_type(
        call_node: call_node, scope: scope,
        receiver_type: Rigor::Type::Combinator.untyped
      )

      expect(type).to eq(relation_type("Post"))
    end

    it "keeps a chained relation query method type-checking cleanly" do
      # `where` opens the relation; every chained query method resolves through the bundled
      # `ActiveRecord::Relation` RBS, so the whole chain stays `Relation[User]`.
      result = run_ar(<<~RUBY)
        users = User.where(admin: true).order(:name).limit(10)
        users.first
      RUBY
      method_undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method"
      end
      expect(method_undefined).to be_empty
    end

    it "does not flag an unknown scope called on a typed relation (ADR-26 open receiver)" do
      # `Post.where(...).some_undeclared_scope` — the relation is typed, but `ActiveRecord::Relation` is an
      # open receiver, so an unenumerable scope call must NOT surface as `call.undefined-method`.
      result = run_ar(
        "Post.where(published: true).some_undeclared_scope\n",
        models: scope_models, schema: scope_schema
      )
      undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method"
      end
      expect(undefined).to be_empty
    end

    it "resolves the block element type through the relation end-to-end" do
      # `where` → Relation[User] → Enumerable[User]#each yields User → the column accessor types `u.name` as
      # String → `bit_length` is undefined on String.
      result = run_ar("User.where(admin: true).each { |u| u.name.bit_length }\n")
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("bit_length")
      end
      expect(undefined).not_to be_nil
      expect(undefined.message).to include("String")
    end
  end
end
