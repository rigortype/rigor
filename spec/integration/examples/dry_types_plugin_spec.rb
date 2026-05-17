# frozen_string_literal: true

# Integration spec for `examples/rigor-dry-types/`. ADR-12 slice 1.
# Exercises the Tier A foundation plugin end-to-end:
#
# 1. Load the example plugin via the `rigor-dry-types` entry point.
# 2. Run rigor against a project that declares
#    `module Types; include Dry.Types(); end`.
# 3. Assert that the plugin publishes the `:dry_type_aliases`
#    fact via the ADR-9 cross-plugin fact store.
#
# Slice 1 has no user-facing diagnostics — the contract is
# fact-publication. Downstream uplifts (rigor-dry-struct's
# slice-6 precision promotion) consume the fact in later
# slices.

require "spec_helper"

DRY_TYPES_PLUGIN_LIB = File.expand_path("../../../examples/rigor-dry-types/lib", __dir__)
$LOAD_PATH.unshift(DRY_TYPES_PLUGIN_LIB) unless $LOAD_PATH.include?(DRY_TYPES_PLUGIN_LIB)
require "rigor-dry-types"

RSpec.describe "rigor-dry-types integration" do
  let(:plugin_class) { Rigor::Plugin::DryTypes }

  let(:dry_types_rbs) do
    <<~RBS
      module Dry
        def self.Types: () -> Module
      end
    RBS
  end

  let(:demo_source) do
    <<~RUBY
      module Types
        include Dry.Types()
      end
    RUBY
  end

  it "registers a manifest publishing :dry_type_aliases" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("dry-types")
    expect(manifest.produces).to include(:dry_type_aliases)
  end

  it "publishes the canonical alias table for `module Types; include Dry.Types(); end`" do
    aliases = run_and_read_fact(demo: demo_source)
    expect(aliases).not_to be_nil
    expect(aliases.fetch("Types::String")).to eq("String")
    expect(aliases.fetch("Types::Integer")).to eq("Integer")
    expect(aliases.fetch("Types::Bool")).to eq("TrueClass")
    expect(aliases.fetch("Types::Nil")).to eq("NilClass")
  end

  it "publishes the four nested-category aliases (Coercible / Strict / Params / JSON) per canonical name" do
    aliases = run_and_read_fact(demo: demo_source)
    %w[Coercible Strict Params JSON].each do |category|
      expect(aliases.fetch("Types::#{category}::String")).to eq("String")
      expect(aliases.fetch("Types::#{category}::Integer")).to eq("Integer")
      expect(aliases.fetch("Types::#{category}::Bool")).to eq("TrueClass")
    end
  end

  it "publishes nested-namespace aliases too (module App; module Types; include Dry.Types(); end; end)" do
    nested = <<~RUBY
      module App
        module Types
          include Dry.Types()
        end
      end
    RUBY
    aliases = run_and_read_fact(demo: nested)
    expect(aliases.fetch("App::Types::String")).to eq("String")
    expect(aliases.fetch("App::Types::Decimal")).to eq("BigDecimal")
  end

  it "publishes user-authored compositions under their head canonical class (slice 3)" do
    composed = <<~RUBY
      module Types
        include Dry.Types()

        Email = String.constrained(format: /@/)
        ManagerEmail = Strict::String
        PositiveInt = Integer.constrained(gt: 0).optional
        ActiveFlag = Bool
      end
    RUBY
    aliases = run_and_read_fact(demo: composed)
    expect(aliases.fetch("Types::Email")).to eq("String")
    expect(aliases.fetch("Types::ManagerEmail")).to eq("String")
    expect(aliases.fetch("Types::PositiveInt")).to eq("Integer")
    expect(aliases.fetch("Types::ActiveFlag")).to eq("TrueClass")
  end

  it "resolves transitive composition references to the head canonical (slice 4)" do
    transitive = <<~RUBY
      module Types
        include Dry.Types()

        Email = String.constrained(format: /@/)
        ManagerEmail = Email
        SeniorManagerEmail = ManagerEmail
        ConstrainedManagerEmail = Email.constrained(min_size: 3)
      end
    RUBY
    aliases = run_and_read_fact(demo: transitive)
    expect(aliases.fetch("Types::Email")).to eq("String")
    expect(aliases.fetch("Types::ManagerEmail")).to eq("String")
    expect(aliases.fetch("Types::SeniorManagerEmail")).to eq("String")
    expect(aliases.fetch("Types::ConstrainedManagerEmail")).to eq("String")
  end

  it "silently drops transitive references that target an unknown constant (slice 4)" do
    dangling = <<~RUBY
      module Types
        include Dry.Types()

        DanglingAlias = NotAComposition
      end
    RUBY
    aliases = run_and_read_fact(demo: dangling)
    expect(aliases).not_to have_key("Types::DanglingAlias")
  end

  it "breaks composition reference cycles silently (slice 4)" do
    cycle = <<~RUBY
      module Types
        include Dry.Types()

        Loopy = LoopyToo
        LoopyToo = Loopy
      end
    RUBY
    aliases = run_and_read_fact(demo: cycle)
    expect(aliases).not_to have_key("Types::Loopy")
    expect(aliases).not_to have_key("Types::LoopyToo")
  end

  it "skips compositions whose RHS is a union (no single underlying class)" do
    union = <<~RUBY
      module Types
        include Dry.Types()
        StringOrInt = String | Integer
      end
    RUBY
    aliases = run_and_read_fact(demo: union)
    expect(aliases).not_to have_key("Types::StringOrInt")
  end

  it "does NOT publish the fact when no `include Dry.Types()` shape is found" do
    plain = <<~RUBY
      module Types
        # Note: no `include Dry.Types()`. The plugin must not
        # publish an alias table from a same-named module that
        # doesn't actually install the dry-types DSL.
        def self.noop; end
      end
    RUBY
    aliases = run_and_read_fact(demo: plain)
    expect(aliases).to be_nil
  end

  # Runs the plugin against a single-file project and returns
  # the `:dry_type_aliases` fact value (or `nil` if the plugin
  # didn't publish it). Captures the per-run `Plugin::Services`
  # instance via `wrap_original` so we can read the fact store
  # after `prepare(services)` ran — same pattern as the
  # rigor-rails-routes integration spec.
  def run_and_read_fact(demo:)
    Rigor::Plugin.unregister!
    captured_store = nil
    allow(Rigor::Plugin::Services).to receive(:new).and_wrap_original do |original, **kwargs|
      services = original.call(**kwargs)
      captured_store = services.fact_store
      services
    end

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "types.rb"), demo)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "dry_types.rbs"), dry_types_rbs)

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "types.rb")],
          "plugins" => ["rigor-dry-types"]
        )
      )

      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin_class)
            true
          end
        ).run
      end
    end
    captured_store&.read(plugin_id: "dry-types", name: :dry_type_aliases)
  end
end
