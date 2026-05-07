# frozen_string_literal: true

# Integration spec for `examples/rigor-activerecord/`. Reference
# coverage for the most architecturally complete v0.1.0 plugin
# example — combines `rigor-routes`-style IoBoundary + cache
# producer (twice — schema and model index), `rigor-lisp-eval`-
# style Prism DSL interpretation (the schema parser), and
# `rigor-statesman`-style two-pass discover-then-validate.

require "spec_helper"
require "fileutils"
require "tmpdir"

ACTIVERECORD_PLUGIN_LIB = File.expand_path("../../../examples/rigor-activerecord/lib", __dir__)
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

RSpec.describe "examples/rigor-activerecord" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Activerecord }
  let(:requirer) do
    lambda do |_name|
      Rigor::Plugin.register(plugin_class)
      true
    end
  end

  def materialize_project(dir, source:, schema: DEFAULT_SCHEMA, models: DEFAULT_MODELS, plugin_config: nil)
    FileUtils.mkdir_p(File.join(dir, "db"))
    File.write(File.join(dir, "db", "schema.rb"), schema)
    models.each do |path, contents|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents)
    end
    File.write(File.join(dir, "demo.rb"), source)
    plugin_entry = plugin_config ? { "gem" => "rigor-activerecord", "config" => plugin_config } : "rigor-activerecord"
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => [File.join(dir, "demo.rb")],
        "plugins" => [plugin_entry]
      )
    )
  end

  def run_plugin(source, **)
    Dir.mktmpdir do |dir|
      configuration = materialize_project(dir, source: source, **)
      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: requirer
        ).run
      end
    end
  end

  def plugin_diagnostics(result)
    result.diagnostics.select { |d| d.source_family == "plugin.activerecord" }
  end

  describe "recognised AR finder calls" do
    it "annotates `Model.find(id)` with the resolved table" do
      diags = plugin_diagnostics(run_plugin("User.find(1)\n"))
      info = diags.find { |d| d.rule == "model-call" }
      expect(info.severity).to eq(:info)
      expect(info.message).to eq("`User.find` returns User (table: `users`)")
      expect(info.qualified_rule).to eq("plugin.activerecord.model-call")
    end

    it "annotates `Model.find_by(col: v)` with the matched column" do
      diags = plugin_diagnostics(run_plugin("User.find_by(email: 'a')\n"))
      expect(diags.first.message).to eq("`User.find_by` (:email) on table `users`")
    end

    it "annotates `Model.where(col: v)` with the matched column" do
      diags = plugin_diagnostics(run_plugin("User.where(admin: true)\n"))
      expect(diags.first.message).to eq("`User.where` (:admin) on table `users`")
    end

    it "recognises `t.references` columns as `<name>_id`" do
      diags = plugin_diagnostics(run_plugin("Post.where(user_id: 1)\n"))
      expect(diags.first.message).to eq("`Post.where` (:user_id) on table `posts`")
    end

    it "uses the Inflector to derive `User → users` / `Post → posts`" do
      diags = plugin_diagnostics(run_plugin("Post.find(42)\n"))
      expect(diags.first.message).to include("table: `posts`")
    end
  end

  describe "unknown-column diagnostics" do
    it "errors on a typo with a Levenshtein-suggested name" do
      diags = plugin_diagnostics(run_plugin("User.where(emial: 'a')\n"))
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err.severity).to eq(:error)
      expect(err.message).to include("unknown column `emial`")
      expect(err.message).to include("did you mean `:email`?")
    end

    it "errors without a hint when no column is close enough" do
      diags = plugin_diagnostics(run_plugin("User.where(foo_bar_baz_quux: 1)\n"))
      err = diags.find { |d| d.rule == "unknown-column" }
      expect(err.message).not_to include("did you mean")
    end

    it "fires once per unknown key in a multi-key call" do
      diags = plugin_diagnostics(run_plugin("Post.where(title: 'x', invented: true)\n"))
      errors = diags.select { |d| d.rule == "unknown-column" }
      expect(errors.size).to eq(1)
      expect(errors.first.message).to include("`invented`")
    end
  end

  describe "wrong-arity diagnostics" do
    it "errors when `find` is called with no arguments" do
      diags = plugin_diagnostics(run_plugin("User.find\n"))
      err = diags.find { |d| d.rule == "wrong-arity" }
      expect(err.severity).to eq(:error)
      expect(err.message).to eq("`User.find` expects at least 1 argument, got 0")
    end
  end

  describe "non-model receivers" do
    it "stays silent when the receiver is not a known model" do
      diags = plugin_diagnostics(run_plugin("Random.where(foo: 1)\n"))
      expect(diags).to be_empty
    end

    it "stays silent when the receiver is a local variable" do
      diags = plugin_diagnostics(run_plugin("user = User.new; user.where(foo: 1)\n"))
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
        run_plugin("User.where(given_name: 'A')\n", models: user_with_override, schema: schema_with_people_table)
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
        run_plugin("Widget.where(label: 'x')\n",
                   schema: schema,
                   models: custom_base_models,
                   plugin_config: { "model_base_classes" => ["DbRecord"] })
      )
      expect(diags.first.message).to eq("`Widget.where` (:label) on table `widgets`")
    end
  end

  describe "graceful failure modes" do
    def run_without_schema_file(source)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-activerecord"]
          )
        )
        Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: nil,
            plugin_requirer: requirer
          ).run
        end
      end
    end

    it "warns when `db/schema.rb` is missing rather than crashing" do
      result = run_without_schema_file("User.find(1)\n")
      warning = result.diagnostics.find { |d| d.rule == "load-error" }
      expect(warning.severity).to eq(:warning)
      expect(warning.message).to include("db/schema.rb")
      expect(warning.message).to include("not found")
    end
  end
end
