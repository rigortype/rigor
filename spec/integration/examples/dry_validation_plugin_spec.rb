# frozen_string_literal: true

# Integration spec for `examples/rigor-dry-validation/`.
# ADR-12 Tier A per the slicing plan in
# `docs/design/20260517-dry-validation-slicing.md`.

require "spec_helper"

DRY_VALIDATION_PLUGIN_LIB = File.expand_path("../../../examples/rigor-dry-validation/lib", __dir__)
$LOAD_PATH.unshift(DRY_VALIDATION_PLUGIN_LIB) unless $LOAD_PATH.include?(DRY_VALIDATION_PLUGIN_LIB)
require "rigor-dry-validation"

RSpec.describe "rigor-dry-validation integration" do
  let(:plugin_class) { Rigor::Plugin::DryValidation }

  let(:dry_validation_rbs) do
    <<~RBS
      module Dry
        module Validation
          class Contract
            def call: (Hash[Symbol, untyped]) -> Result
          end
          class Result
            def success?: () -> bool
            def to_h: () -> Hash[Symbol, untyped]
          end
        end
      end
    RBS
  end

  it "registers a manifest publishing :dry_validation_contracts" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("dry-validation")
    expect(manifest.produces).to include(:dry_validation_contracts)
  end

  it "publishes the contract FQN set for `class T < Dry::Validation::Contract`" do
    demo = <<~RUBY
      class NewUserContract < Dry::Validation::Contract
        params do
          required(:email).filled(:string)
        end
      end

      class UpdateUserContract < Dry::Validation::Contract
        params do
          required(:email).filled(:string)
        end
      end
    RUBY
    contracts = run_and_read_fact(demo: demo)
    expect(contracts).to contain_exactly("NewUserContract", "UpdateUserContract")
  end

  it "recognises the lexical-Dry path (`< Validation::Contract`)" do
    demo = <<~RUBY
      module Dry
        class EmailContract < Validation::Contract
          params { required(:email).filled(:string) }
        end
      end
    RUBY
    contracts = run_and_read_fact(demo: demo)
    expect(contracts).to contain_exactly("Dry::EmailContract")
  end

  it "ignores unrelated subclasses whose superclass tail is `Contract`" do
    demo = <<~RUBY
      class FooContract < ActiveModel::Contract
        # not a dry-validation Contract
      end
      class BareContract < Contract
        # bare `Contract` — too ambiguous; not recognised
      end
      class FakeContract < MyApp::Validation::Contract
        # different root — not dry-validation
      end
    RUBY
    expect(run_and_read_fact(demo: demo)).to be_nil
  end

  it "registers nested contracts under the enclosing constant chain" do
    demo = <<~RUBY
      module App
        module Contracts
          class CreateUser < Dry::Validation::Contract
            params { required(:email).filled(:string) }
          end
        end
      end
    RUBY
    expect(run_and_read_fact(demo: demo)).to contain_exactly("App::Contracts::CreateUser")
  end

  it "publishes the sorted, frozen list (deterministic ordering across runs)" do
    demo = <<~RUBY
      class ZetaContract < Dry::Validation::Contract; end
      class AlphaContract < Dry::Validation::Contract; end
      class MikeContract < Dry::Validation::Contract; end
    RUBY
    contracts = run_and_read_fact(demo: demo)
    expect(contracts).to eq(%w[AlphaContract MikeContract ZetaContract])
    expect(contracts).to be_frozen
  end

  it "does NOT publish the fact when no Contract subclass is present" do
    demo = <<~RUBY
      class Foo; end
    RUBY
    expect(run_and_read_fact(demo: demo)).to be_nil
  end

  describe "RBS overlay (sig/dry_validation.rbs)" do
    it "ships as part of the gem" do
      sig_path = File.expand_path("../../../examples/rigor-dry-validation/sig/dry_validation.rbs", __dir__)
      expect(File).to exist(sig_path)
      contents = File.read(sig_path, encoding: "UTF-8")
      expect(contents).to include("class Contract")
      expect(contents).to include("def call:")
      expect(contents).to include("class Result")
      expect(contents).to include("def to_h:")
    end
  end

  def run_and_read_fact(demo:)
    Rigor::Plugin.unregister!
    captured_store = nil
    allow(Rigor::Plugin::Services).to receive(:new).and_wrap_original do |original, **kwargs|
      services = original.call(**kwargs)
      captured_store = services.fact_store
      services
    end

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "contracts.rb"), demo)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "dry_validation.rbs"), dry_validation_rbs)

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "contracts.rb")],
          "plugins" => ["rigor-dry-validation"]
        )
      )

      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin_class)
            true
          end
        ).run
      end
    end
    captured_store&.read(plugin_id: "dry-validation", name: :dry_validation_contracts)
  end
end
