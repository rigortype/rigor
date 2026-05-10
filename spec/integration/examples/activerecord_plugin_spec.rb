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

USER_RBS_FOR_NARROWING = <<~RBS
  class User
    attr_accessor name: String
    attr_accessor email: String
  end
RBS

RSpec.describe "examples/rigor-activerecord" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Activerecord }

  def run_ar(source, schema: DEFAULT_SCHEMA, models: DEFAULT_MODELS, plugin_config: nil)
    files = { "db/schema.rb" => schema }.merge(models)
    plugin_entry = plugin_config ? { "gem" => "rigor-activerecord", "config" => plugin_config } : nil
    run_plugin(source: source, plugin_entry: plugin_entry, files: files)
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

    it "leaves `Model.where` at the RBS untyped return (relations deferred)" do
      result = run_ar_with_user_sig(<<~RUBY)
        users = User.where(admin: true)
        users.bit_length
      RUBY
      # No contribution → RBS untyped → no method-undefined.
      method_undefined = result.diagnostics.select do |d|
        d.path.end_with?("demo.rb") && d.rule == "call.undefined-method" && d.message.include?("bit_length")
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

    def run_two_plugins(source, schema:, models:) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
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
end
