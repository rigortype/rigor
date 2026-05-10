# frozen_string_literal: true

# Integration spec for `examples/rigor-factorybot/`. Phase 1
# (a) — self-contained validation of FactoryBot entry calls
# against a per-run factory index.

require "spec_helper"

FACTORYBOT_PLUGIN_LIB = File.expand_path("../../../examples/rigor-factorybot/lib", __dir__)
$LOAD_PATH.unshift(FACTORYBOT_PLUGIN_LIB) unless $LOAD_PATH.include?(FACTORYBOT_PLUGIN_LIB)
require "rigor-factorybot"

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
end
