# frozen_string_literal: true

# Integration spec for `plugins/rigor-dry-validation/`. ADR-12 Tier A per the slicing plan in
# `docs/design/20260517-dry-validation-slicing.md`.

require "spec_helper"

DRY_VALIDATION_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-dry-validation/lib", __dir__)
$LOAD_PATH.unshift(DRY_VALIDATION_PLUGIN_LIB) unless $LOAD_PATH.include?(DRY_VALIDATION_PLUGIN_LIB)
require "rigor-dry-validation"

DRY_SCHEMA_PLUGIN_LIB_FOR_VALIDATION = File.expand_path("../../../plugins/rigor-dry-schema/lib", __dir__)
unless $LOAD_PATH.include?(DRY_SCHEMA_PLUGIN_LIB_FOR_VALIDATION)
  $LOAD_PATH.unshift(DRY_SCHEMA_PLUGIN_LIB_FOR_VALIDATION)
end
require "rigor-dry-schema"

DRY_TYPES_PLUGIN_LIB_FOR_VALIDATION = File.expand_path("../../../plugins/rigor-dry-types/lib", __dir__)
$LOAD_PATH.unshift(DRY_TYPES_PLUGIN_LIB_FOR_VALIDATION) unless $LOAD_PATH.include?(DRY_TYPES_PLUGIN_LIB_FOR_VALIDATION)
require "rigor-dry-types"

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
      sig_path = File.expand_path("../../../plugins/rigor-dry-validation/sig/dry_validation.rbs", __dir__)
      expect(File).to exist(sig_path)
      contents = File.read(sig_path, encoding: "UTF-8")
      expect(contents).to include("class Contract")
      expect(contents).to include("def call:")
      expect(contents).to include("class Result")
      expect(contents).to include("def to_h:")
    end
  end

  # Slices 2/3 (issue #137) — `params { ... }` / `json { ... }` integration with rigor-dry-schema.
  describe "params/json schema integration (slices 2/3)" do
    it "publishes :dry_validation_params for a Contract's `params { ... }` block" do
      demo = <<~RUBY
        class NewUserContract < Dry::Validation::Contract
          params do
            required(:email).filled(:string)
            required(:age).value(:integer)
          end
        end
      RUBY
      table = run_and_read_params_fact(demo: demo)
      entry = table.fetch("NewUserContract")
      expect(entry.fetch(:params).fetch(:required)).to eq(
        email: { type: "String", list: false },
        age: { type: "Integer", list: false }
      )
    end

    it "publishes :dry_validation_params for a Contract's `json { ... }` block" do
      demo = <<~RUBY
        class ImportContract < Dry::Validation::Contract
          json do
            required(:sku).filled(:string)
          end
        end
      RUBY
      table = run_and_read_params_fact(demo: demo)
      expect(table.fetch("ImportContract").fetch(:json).fetch(:required)).to eq(
        sku: { type: "String", list: false }
      )
    end

    it "does NOT publish :dry_validation_params when rigor-dry-schema isn't loaded" do
      demo = <<~RUBY
        class NewUserContract < Dry::Validation::Contract
          params do
            required(:email).filled(:string)
          end
        end
      RUBY
      expect(run_and_read_params_fact(demo: demo, with_dry_schema: false)).to be_nil
    end

    it "does NOT capture a `params { ... }` call that isn't a direct top-level class-body statement" do
      demo = <<~RUBY
        class ConditionalContract < Dry::Validation::Contract
          if true
            params do
              required(:email).filled(:string)
            end
          end
        end
      RUBY
      expect(run_and_read_params_fact(demo: demo)).to be_nil
    end

    it "refines `Contract.new.call(input).to_h` to the params schema's HashShape" do
      dump = dump_types(<<~RUBY).first
        class NewUserContract < Dry::Validation::Contract
          params do
            required(:email).filled(:string)
            required(:age).value(:integer)
          end
        end

        Rigor.dump_type(NewUserContract.new.call({}).to_h)
      RUBY
      expect(dump).to include("email", "String", "age", "Integer")
    end

    it "refines `Contract.new.call(input).to_h` to the json schema's HashShape" do
      dump = dump_types(<<~RUBY).first
        class ImportContract < Dry::Validation::Contract
          json do
            required(:sku).filled(:string)
          end
        end

        Rigor.dump_type(ImportContract.new.call({}).to_h)
      RUBY
      expect(dump).to include("sku", "String")
    end

    it "keeps the generic Hash[Symbol, untyped] shape when rigor-dry-schema isn't loaded" do
      dump = dump_types(<<~RUBY, with_dry_schema: false).first
        class NewUserContract < Dry::Validation::Contract
          params do
            required(:email).filled(:string)
          end
        end

        Rigor.dump_type(NewUserContract.new.call({}).to_h)
      RUBY
      expect(dump).not_to include("email")
    end

    it "contributes nothing for a Contract with no params/json block at all" do
      dumps = dump_types(<<~RUBY)
        class EmptyContract < Dry::Validation::Contract
        end

        Rigor.dump_type(EmptyContract.new.call({}).to_h)
      RUBY
      expect(dumps.first).not_to include("=>")
    end

    it "resolves a params row's constant type reference through :dry_type_aliases too" do
      demo = <<~RUBY
        module Types
          include Dry.Types()

          Email = String.constrained(format: /@/)
        end

        class NewUserContract < Dry::Validation::Contract
          params do
            required(:email).value(Types::Email)
          end
        end
      RUBY
      table = run_and_read_params_fact(demo: demo, with_dry_types: true)
      expect(table.fetch("NewUserContract").fetch(:params).fetch(:required)).to eq(
        email: { type: "String", list: false }
      )
    end
  end

  # Runs the plugin(s) against a single-file project and returns the `dump.type` messages, in source order.
  def dump_types(demo, with_dry_schema: true)
    run_demo(demo, with_dry_schema: with_dry_schema).diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
  end

  def run_demo(demo, with_dry_schema: true, with_dry_types: false)
    plugin_entries = ["rigor-dry-validation"]
    plugin_entries << "rigor-dry-schema" if with_dry_schema
    plugin_entries << "rigor-dry-types" if with_dry_types

    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "contracts.rb"), demo)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "dry_validation.rbs"), dry_validation_rbs)
      run_analysis(dir: dir, plugin_entries: plugin_entries)
    end
  end

  # Runs the plugin(s) against a single-file project and returns the `:dry_validation_params` fact value.
  def run_and_read_params_fact(demo:, with_dry_schema: true, with_dry_types: false)
    plugin_entries = ["rigor-dry-validation"]
    plugin_entries << "rigor-dry-schema" if with_dry_schema
    plugin_entries << "rigor-dry-types" if with_dry_types

    Rigor::Plugin.unregister!
    captured_store = capture_fact_store!
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "contracts.rb"), demo)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "dry_validation.rbs"), dry_validation_rbs)
      run_analysis(dir: dir, plugin_entries: plugin_entries)
    end
    captured_store.call&.read(plugin_id: "dry-validation", name: :dry_validation_params)
  end

  def capture_fact_store!
    captured = nil
    allow(Rigor::Plugin::Services).to receive(:new).and_wrap_original do |original, **kwargs|
      services = original.call(**kwargs)
      captured = services.fact_store
      services
    end
    -> { captured }
  end

  def run_analysis(dir:, plugin_entries:)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => [File.join(dir, "contracts.rb")],
        "plugins" => plugin_entries
      )
    )

    Dir.chdir(dir) do
      Rigor::Analysis::Runner.new(
        configuration: configuration, cache_store: nil,
        plugin_requirer: lambda do |name|
          # #194 slice 2 — a bundled plugin arrives as its engine-anchored absolute path; basename
          # recovers the gem name (a bare name passes through unchanged).
          case File.basename(name, ".rb")
          when "rigor-dry-types" then Rigor::Plugin.register(Rigor::Plugin::DryTypes)
          when "rigor-dry-schema" then Rigor::Plugin.register(Rigor::Plugin::DrySchema)
          when "rigor-dry-validation" then Rigor::Plugin.register(Rigor::Plugin::DryValidation)
          end
          true
        end
      ).run
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
