# frozen_string_literal: true

# Integration spec for `plugins/rigor-activerecord/`. Reference
# coverage for the most architecturally complete v0.1.0 plugin
# example — combines `rigor-routes`-style IoBoundary + cache
# producer (twice — schema and model index), `rigor-lisp-eval`-
# style Prism DSL interpretation (the schema parser), and
# `rigor-statesman`-style two-pass discover-then-validate.

require "spec_helper"
require "fileutils"
require "tmpdir"

# `ACTIVERECORD_PLUGIN_LIB` is also defined by
# `factorybot_plugin_spec.rb` (which consumes the activerecord
# plugin's `:model_index` facts). Guard against the double
# definition so running both specs in the same process does
# not warn `already initialized constant`.
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

  def run_ar(source, schema: DEFAULT_SCHEMA, models: DEFAULT_MODELS, plugin_config: nil)
    files = { "db/schema.rb" => schema }.merge(models)
    plugin_entry = plugin_config ? { "gem" => "rigor-activerecord", "config" => plugin_config } : nil
    run_plugin(source: source, plugin_entry: plugin_entry, files: files)
  end

  # Materialises the project files, runs the analyser
  # directly, and returns `[result, model_index]` so the
  # AR-extension specs can assert against BOTH the diagnostic
  # stream and the structured per-model state (enums /
  # scopes / validations / callbacks). The `model_index`
  # accessor isn't surfaced through `run_plugin` because the
  # other plugin examples don't need it.
  def run_ar_with_index(source, models:, schema:)
    files = { "db/schema.rb" => schema, "demo.rb" => source }.merge(models)
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
    it "warns when `db/schema.rb` is missing rather than crashing" do
      # No `files:` argument — no schema.rb gets written.
      result = run_plugin(source: "User.find(1)\n")
      warning = result.diagnostics.find { |d| d.rule == "load-error" }
      expect(warning.severity).to eq(:warning)
      expect(warning.message).to include("db/schema.rb")
      expect(warning.message).to include("not found")
    end

    it "emits the load-error warning at most once across many analyzed files" do
      # Solidus monorepo / Redmine (migrations-only) scale: hundreds
      # of files, but `db/schema.rb` absence is a single
      # project-global root cause. Pre-fix the plugin emitted
      # `load-error` per file (346× on Redmine).
      result = run_plugin(
        source: "User.find(1)\n",
        files: { "extra1.rb" => "stuff\n", "extra2.rb" => "more\n", "extra3.rb" => "again\n" }
      )
      load_errors = result.diagnostics.select { |d| d.rule == "load-error" }
      expect(load_errors.size).to eq(1)
    end
  end

  describe "#flow_contribution_for return-type contribution (v0.1.2)" do
    # The plugin's `Model.find(id)` rule contributes
    # `Nominal[Model]` so chained call sites resolve through
    # the analyzer's normal dispatch — without the contribution
    # the RBS-level untyped return would let any chained method
    # name through silently. The `call.undefined-method` rule
    # only fires when the receiver class is known to RBS, so the
    # tests below ship an RBS sig for User (top-level
    # `USER_RBS_FOR_NARROWING`) declaring its columns.
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

    it "narrows `Model.where` to a relation so a non-relation method surfaces" do
      result = run_ar_with_user_sig(<<~RUBY)
        users = User.where(admin: true)
        users.bit_length
      RUBY
      # `where` → `ActiveRecord::Relation[User]`; `bit_length`
      # is on neither the relation nor Enumerable.
      method_undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("bit_length")
      end
      expect(method_undefined).not_to be_nil
    end

    it "keeps a chained relation query method type-checking cleanly" do
      # Plain `run_ar` (no model RBS): `where` opens the relation
      # and every chained query method resolves through the
      # bundled `ActiveRecord::Relation` RBS, so the whole chain
      # stays `ActiveRecord::Relation[User]` with nothing flagged.
      result = run_ar(<<~RUBY)
        users = User.where(admin: true).order(:name).limit(10)
        users.first
      RUBY
      method_undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method"
      end
      expect(method_undefined).to be_empty
    end

    it "does not contribute on non-model receivers" do
      result = run_ar_with_user_sig(<<~RUBY)
        x = Object.find(1)
        x.upcase
      RUBY
      # Object.find isn't a model — no contribution; the call
      # falls through to the analyzer's normal dispatch.
      method_undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("upcase")
      end
      expect(method_undefined).to be_empty
    end
  end

  describe "associations (has_many / belongs_to / has_one) — v0.1.5" do
    # rigor-activerecord now records `has_many` / `belongs_to`
    # / `has_one` declarations in the ModelIndex (and
    # contributes `Nominal[Target] | nil` for the singular
    # cases via `flow_contribution_for`). The integration
    # spec asserts via the model-index lookup that the right
    # rows landed; the singular flow contribution is covered
    # via direct unit specs on the plugin classes
    # (`spec/examples/activerecord/` — not bundled here).

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
      # `belongs_to` is required (non-`nil`) by default since
      # Rails 5, so `post.user` narrows to `Nominal[User]` with no
      # nil arm. Spec the contribution shape directly on the plugin
      # instance — Rigor's diagnostic rule contract for chained
      # calls is independent of the plugin's return-type publication.
      index = model_index_after_run(models: POST_USER_MODELS)
      runner_plugin = Rigor::Plugin::Activerecord.allocate
      runner_plugin.instance_variable_set(:@model_index, index)

      call_node = Prism.parse("post.user").value.statements.body.first
      double_scope = Object.new
      double_scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("Post")
      end
      contribution = runner_plugin.flow_contribution_for(call_node: call_node, scope: double_scope)

      expect(contribution).to be_a(Rigor::FlowContribution)
      expect(contribution.return_type).to eq(Rigor::Type::Combinator.nominal_of("User"))
    end

    it "publishes a nullable `Nominal[Target] | nil` for has_one" do
      # `has_one` genuinely returns `nil` when no associated
      # record exists, so `user.profile` keeps the nil arm.
      index = model_index_after_run(models: POST_USER_MODELS)
      runner_plugin = Rigor::Plugin::Activerecord.allocate
      runner_plugin.instance_variable_set(:@model_index, index)

      call_node = Prism.parse("user.profile").value.statements.body.first
      double_scope = Object.new
      double_scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of("User")
      end
      contribution = runner_plugin.flow_contribution_for(call_node: call_node, scope: double_scope)

      expect(contribution.return_type).to eq(
        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.nominal_of("Profile"),
          Rigor::Type::Combinator.constant_of(nil)
        )
      )
    end

    it "publishes a nullable type for `belongs_to ..., optional: true`" do
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
      contribution = runner_plugin.flow_contribution_for(call_node: call_node, scope: double_scope)

      expect(contribution.return_type).to eq(
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
      contribution = runner_plugin.flow_contribution_for(call_node: call_node, scope: double_scope)

      expect(contribution.return_type).to eq(
        Rigor::Type::Combinator.nominal_of(
          "ActiveRecord::Relation",
          type_args: [Rigor::Type::Combinator.nominal_of("Post")]
        )
      )
    end

    it "accepts a singular association name as a `find_by` / `where` key alias" do
      # Mastodon-derived regression: `AccountPin.find_by(account: x)`
      # passes the belongs_to association name `:account` instead of
      # the FK column `:account_id`. ActiveRecord accepts both; the
      # plugin should match. Pre-fix this was 100+ FPs on Mastodon's
      # API controllers.
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
      # `posts` would be a has_many (collection) association on a
      # hypothetical reverse relationship; it's not declared here at
      # all, so the plugin should still error.
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
    # Loads rigor-activerecord (the producer) alongside a
    # synthetic consumer plugin that reads the published
    # :model_index in its `prepare(services)` hook and emits
    # a diagnostic naming the column set it sees. This is the
    # same shape rigor-actionpack Phase 1 / rigor-factorybot
    # Phase 1 (c) will use; the test pins the publication
    # contract.
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
              case name
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
      # DEFAULT_SCHEMA's `posts` table has a plain
      # `t.references "user"` — no `user_type` column exists.
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
    def flow_contribution_for_call(index:, source:, receiver_class:)
      plugin = Rigor::Plugin::Activerecord.allocate
      plugin.instance_variable_set(:@model_index, index)
      call_node = Prism.parse(source).value.statements.body.first
      scope = Object.new
      scope.define_singleton_method(:type_of) do |_node|
        Rigor::Type::Combinator.nominal_of(receiver_class)
      end
      plugin.flow_contribution_for(call_node: call_node, scope: scope)
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
        contribution = flow_contribution_for_call(
          index: index, source: "comment.commentable", receiver_class: "Comment"
        )
        expect(contribution).to be_nil
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
        contribution = flow_contribution_for_call(
          index: index, source: "account.balance", receiver_class: "Account"
        )
        expect(contribution.return_type).to eq(Rigor::Type::Combinator.nominal_of("Money"))
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
      # `belongs_to :company` is declared on User; the child must
      # accept `:company` as a query key or it is a false positive.
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
      plugin.flow_contribution_for(call_node: call_node, scope: scope)
    end

    let(:bool_union) do
      Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(true),
        Rigor::Type::Combinator.constant_of(false)
      )
    end

    it "contributes the column value type for a string accessor" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      contribution = column_contribution(index: index, source: "user.name", receiver_class: "User")

      expect(contribution.return_type).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "contributes Integer for the implicit `id` column" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      contribution = column_contribution(index: index, source: "user.id", receiver_class: "User")

      expect(contribution.return_type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "contributes `bool` for a boolean column accessor" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      contribution = column_contribution(index: index, source: "user.admin", receiver_class: "User")

      expect(contribution.return_type).to eq(bool_union)
    end

    it "contributes `bool` for the generated `<column>?` predicate" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      contribution = column_contribution(index: index, source: "user.name?", receiver_class: "User")

      expect(contribution.return_type).to eq(bool_union)
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
      contribution = column_contribution(index: index, source: "account.preferences", receiver_class: "Account")

      expect(contribution).to be_nil
    end

    it "declines for a method that is neither a column nor an association" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      contribution = column_contribution(index: index, source: "user.totally_unknown", receiver_class: "User")

      expect(contribution).to be_nil
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
  end

  describe "ActiveRecord::Relation typing" do
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
      plugin.flow_contribution_for(call_node: call_node, scope: scope)
    end

    it "declares the bundled relation RBS via signature_paths" do
      expect(plugin_class.manifest.signature_paths).to eq(["sig"])
    end

    it "contributes `ActiveRecord::Relation[Model]` for `Model.where`" do
      _result, index = run_ar_with_index("x = 1\n", models: DEFAULT_MODELS, schema: DEFAULT_SCHEMA)
      contribution = relation_contribution(index: index, source: "User.where(admin: true)", receiver_class: "User")

      expect(contribution.return_type).to eq(relation_type("User"))
    end

    it "contributes a relation for a user-declared `scope`" do
      models = {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/post.rb" => <<~RUBY
          class Post < ApplicationRecord
            scope :published, -> { where(published: true) }
          end
        RUBY
      }
      schema = <<~SCHEMA
        ActiveRecord::Schema[8.0].define do
          create_table "posts", force: :cascade do |t|
            t.boolean "published"
          end
        end
      SCHEMA
      _result, index = run_ar_with_index("x = 1\n", models: models, schema: schema)
      contribution = relation_contribution(index: index, source: "Post.published", receiver_class: "Post")

      expect(contribution.return_type).to eq(relation_type("Post"))
    end

    it "contributes a relation for a `has_and_belongs_to_many` accessor" do
      models = {
        "app/models/application_record.rb" => "class ApplicationRecord\nend\n",
        "app/models/post.rb" => <<~RUBY
          class Post < ApplicationRecord
            has_and_belongs_to_many :tags
          end
        RUBY
      }
      _result, index = run_ar_with_index("x = 1\n", models: models, schema: DEFAULT_SCHEMA)
      contribution = relation_contribution(index: index, source: "post.tags", receiver_class: "Post")

      expect(contribution.return_type).to eq(relation_type("Tag"))
    end

    it "resolves the block element type through the relation end-to-end" do
      # `where` → Relation[User] → Enumerable[User]#each yields
      # User → the column accessor types `u.name` as String →
      # `bit_length` is undefined on String.
      result = run_ar("User.where(admin: true).each { |u| u.name.bit_length }\n")
      undefined = result.diagnostics.find do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("bit_length")
      end
      expect(undefined).not_to be_nil
      expect(undefined.message).to include("String")
    end
  end
end
