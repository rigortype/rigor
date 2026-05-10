# frozen_string_literal: true

# Integration spec for `examples/rigor-factorybot/`. Phase 1
# (a) — self-contained validation of FactoryBot entry calls
# against a per-run factory index.

require "spec_helper"

FACTORYBOT_PLUGIN_LIB = File.expand_path("../../../examples/rigor-factorybot/lib", __dir__)
ACTIVERECORD_PLUGIN_LIB = File.expand_path("../../../examples/rigor-activerecord/lib", __dir__)
$LOAD_PATH.unshift(FACTORYBOT_PLUGIN_LIB) unless $LOAD_PATH.include?(FACTORYBOT_PLUGIN_LIB)
$LOAD_PATH.unshift(ACTIVERECORD_PLUGIN_LIB) unless $LOAD_PATH.include?(ACTIVERECORD_PLUGIN_LIB)
require "rigor-factorybot"
require "rigor-activerecord"

PHASE1C_USERS_FACTORY = <<~RUBY
  FactoryBot.define do
    factory :user do
      name { "Alice" }
    end
  end
RUBY

PHASE1C_SCHEMA = <<~SCHEMA
  ActiveRecord::Schema.define do
    create_table :users do |t|
      t.string :name
      t.string :email
      t.string :role
    end
  end
SCHEMA

PHASE1C_USER_MODEL = "class User < ApplicationRecord\nend\n"

DEFAULT_USERS_FACTORY_RB = <<~RUBY
  FactoryBot.define do
    factory :user do
      name { "Alice" }
      email { "alice@example.com" }
      role { "member" }
    end

    factory :post do
      title { "Hello" }
      body { "" }
    end
  end
RUBY

RSpec.describe "examples/rigor-factorybot" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Factorybot }

  describe "recognised entry calls" do
    it "emits a `factory-call` info trace for `FactoryBot.create(:user)`" do
      result = run_plugin(
        source: "FactoryBot.create(:user)\n",
        files: { "spec/factories/users.rb" => DEFAULT_USERS_FACTORY_RB }
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "factory-call" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to include(":user")
      expect(info.message).to include("name, email, role")
    end

    it "recognises every entry method (build / build_stubbed / attributes_for / *_list)" do
      result = run_plugin(
        source: <<~RUBY,
          FactoryBot.build(:user)
          FactoryBot.build_stubbed(:user)
          FactoryBot.attributes_for(:user)
          FactoryBot.create_list(:user, 3)
        RUBY
        files: { "spec/factories/users.rb" => DEFAULT_USERS_FACTORY_RB }
      )
      infos = plugin_diagnostics(result).select { |d| d.rule == "factory-call" }
      expect(infos.length).to eq(4)
    end

    it "recognises the legacy FactoryGirl receiver" do
      result = run_plugin(
        source: "FactoryGirl.create(:user)\n",
        files: { "spec/factories/users.rb" => DEFAULT_USERS_FACTORY_RB }
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "factory-call" }
      expect(info).not_to be_nil
    end

    it "stays silent on entry calls with non-literal factory names (passes through)" do
      result = run_plugin(
        source: <<~RUBY,
          name = :user
          FactoryBot.create(name)
        RUBY
        files: { "spec/factories/users.rb" => DEFAULT_USERS_FACTORY_RB }
      )
      diags = plugin_diagnostics(result)
      expect(diags).to be_empty
    end

    it "stays silent on plain `create(...)` calls (no FactoryBot receiver)" do
      result = run_plugin(
        source: "create(:user)\n",
        files: { "spec/factories/users.rb" => DEFAULT_USERS_FACTORY_RB }
      )
      diags = plugin_diagnostics(result)
      expect(diags).to be_empty
    end
  end

  describe "error diagnostics" do
    it "fires `unknown-factory` with a did-you-mean suggestion on a typo" do
      result = run_plugin(
        source: "FactoryBot.create(:usre)\n",
        files: { "spec/factories/users.rb" => DEFAULT_USERS_FACTORY_RB }
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-factory" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:error)
      expect(err.message).to include(":usre")
      expect(err.message).to include("Did you mean `:user`?")
    end

    it "fires `unknown-attribute` with a did-you-mean suggestion on a typo'd kwarg" do
      result = run_plugin(
        source: "FactoryBot.create(:user, name: \"X\", rol: \"admin\")\n",
        files: { "spec/factories/users.rb" => DEFAULT_USERS_FACTORY_RB }
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-attribute" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:error)
      expect(err.message).to include(":rol")
      expect(err.message).to include("Did you mean `:role`?")
    end

    it "passes a literal-key kwarg whose name matches a declared attribute" do
      result = run_plugin(
        source: "FactoryBot.create(:user, name: \"X\", email: \"a@b.c\")\n",
        files: { "spec/factories/users.rb" => DEFAULT_USERS_FACTORY_RB }
      )
      errs = plugin_diagnostics(result).select { |d| d.rule == "unknown-attribute" }
      expect(errs).to be_empty
    end
  end

  describe "factory discovery" do
    it "picks up factories from a single-file `spec/factories.rb`" do
      result = run_plugin(
        source: "FactoryBot.create(:user)\n",
        files: {
          "spec/factories.rb" => "FactoryBot.define do\n  factory :user do\n    name { 'X' }\n  end\nend\n"
        }
      )
      info = plugin_diagnostics(result).find { |d| d.rule == "factory-call" }
      expect(info).not_to be_nil
    end

    it "skips `add_attribute` and method_missing forms inside trait blocks (Phase 1 (a) limitation)" do # rubocop:disable RSpec/ExampleLength
      result = run_plugin(
        source: "FactoryBot.create(:user, only_in_trait: true)\n",
        files: {
          "spec/factories/users.rb" => <<~RUBY
            FactoryBot.define do
              factory :user do
                name { "Alice" }
                trait :admin do
                  only_in_trait { true }
                end
              end
            end
          RUBY
        }
      )
      # `:only_in_trait` is declared inside `trait :admin do
      # ... end`, which Phase 1 (a) doesn't recurse into.
      # Hence the kwarg surfaces as `unknown-attribute`.
      err = plugin_diagnostics(result).find { |d| d.rule == "unknown-attribute" }
      expect(err).not_to be_nil
    end
  end

  describe "Phase 1 (c) AR column cross-check" do
    def run_factorybot_with_ar(source) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      Rigor::Plugin.unregister!
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec", "factories"))
        FileUtils.mkdir_p(File.join(dir, "db"))
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "spec", "factories", "users.rb"), PHASE1C_USERS_FACTORY)
        File.write(File.join(dir, "db", "schema.rb"), PHASE1C_SCHEMA)
        File.write(File.join(dir, "app", "models", "user.rb"), PHASE1C_USER_MODEL)
        File.write(File.join(dir, "demo.rb"), source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => %w[rigor-activerecord rigor-factorybot]
          )
        )
        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil,
            plugin_requirer: lambda { |name|
              case name
              when "rigor-activerecord" then Rigor::Plugin.register(Rigor::Plugin::Activerecord)
              when "rigor-factorybot" then Rigor::Plugin.register(Rigor::Plugin::Factorybot)
              end
              true
            }
          )
          yield runner.run
        end
      end
    end

    it "accepts a column-only kwarg that's NOT in the factory's declared attributes" do
      # The factory only declares `:name`. Without the AR
      # cross-check, `:email` would surface as
      # unknown-attribute. With Phase 1 (c) the email column
      # is in the model's index, so the kwarg is accepted.
      run_factorybot_with_ar("FactoryBot.create(:user, email: \"x@y.z\")\n") do |result|
        unknown = result.diagnostics.select do |d|
          d.source_family == "plugin.factorybot" && d.rule == "unknown-attribute"
        end
        expect(unknown).to be_empty
      end
    end

    it "still flags a kwarg that's neither a factory attr nor a model column" do
      run_factorybot_with_ar("FactoryBot.create(:user, totally_unknown: 42)\n") do |result|
        err = result.diagnostics.find do |d|
          d.source_family == "plugin.factorybot" && d.rule == "unknown-attribute"
        end
        expect(err).not_to be_nil
        expect(err.message).to include("totally_unknown")
      end
    end

    it "leaves the unknown-factory diagnostic firing on a typo'd factory name" do
      run_factorybot_with_ar("FactoryBot.create(:usre, email: \"x\")\n") do |result|
        err = result.diagnostics.find do |d|
          d.source_family == "plugin.factorybot" && d.rule == "unknown-factory"
        end
        expect(err).not_to be_nil
      end
    end
  end
end
