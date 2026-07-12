# frozen_string_literal: true

# Integration spec for `plugins/rigor-dry-types/`. ADR-12 slice 1. Exercises the Tier A foundation plugin end-to-end:
#
# 1. Load the example plugin via the `rigor-dry-types` entry point.
# 2. Run rigor against a project that declares `module Types; include Dry.Types(); end`.
# 3. Assert that the plugin publishes the `:dry_type_aliases` fact via the ADR-9 cross-plugin fact store.
#
# Slice 1 has no user-facing diagnostics — the contract is fact-publication. Downstream uplifts
# (rigor-dry-struct's slice-6 precision promotion) consume the fact in later slices.

require "spec_helper"

DRY_TYPES_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-dry-types/lib", __dir__)
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

  # Regression (ADR-60 WD3 / ADR-45 pundit precedent): the `:dry_type_aliases` producer replaced the old
  # uncached `#prepare` scan, which Prism-parsed the whole project tree on every invocation. The producer's
  # `watch:` glob must cover every `.rb` file the alias scan reads, so a change to any file under the
  # project's `paths:` tree — a content edit OR a file addition — invalidates the cross-process cache. A
  # stale alias table served across two `rigor check` processes sharing one on-disk cache is the exact
  # manufactured-stale-result failure the watch machinery exists to prevent.
  describe "cross-process cache invalidation" do
    after { Rigor::Plugin.unregister! }

    # A dry-types module whose `Email` composition resolves to `underlying`. Flipping `underlying` between
    # processes is the single-key mutation the freshness assertion keys on.
    def types_module(underlying:)
      <<~RUBY
        module Types
          include Dry.Types()
          Email = #{underlying}.constrained(min_size: 1)
        end
      RUBY
    end

    # Runs the dry-types plugin against `models_dir` (the project `paths:`) using a FRESH `Cache::Store` at
    # `cache_root` — a fresh store with an empty in-process memo is the faithful stand-in for a second
    # `rigor check` process reading the same on-disk cache, the only configuration in which a missing watch
    # entry surfaces as stale output. Returns `[alias_table_or_nil, cache_store]`.
    def run_dry_types(project_dir:, models_dir:, cache_root:)
      Rigor::Plugin.unregister!
      captured_fact_store = nil
      allow(Rigor::Plugin::Services).to receive(:new).and_wrap_original do |original, **kwargs|
        services = original.call(**kwargs)
        captured_fact_store = services.fact_store
        services
      end

      cache_store = Rigor::Cache::Store.new(root: cache_root)
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [models_dir],
          "plugins" => ["rigor-dry-types"]
        )
      )
      Dir.chdir(project_dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: cache_store,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin_class)
            true
          end
        ).run
      end
      [captured_fact_store&.read(plugin_id: "dry-types", name: :dry_type_aliases), cache_store]
    end

    def producer_stats(cache_store)
      cache_store.stats[:by_producer].fetch(
        "plugin.dry-types.dry_type_aliases", { hits: 0, misses: 0, writes: 0 }
      )
    end

    # Lays out `<project>/models/` (the analyzed `paths:`) + a sibling `sig/` so `Dry.Types()` resolves, then
    # yields the project / models / cache roots. Mirrors the pundit cross-process fixture layout.
    def with_project
      Dir.mktmpdir do |project_dir|
        Dir.mktmpdir do |cache_root|
          models_dir = File.join(project_dir, "models")
          FileUtils.mkdir_p(models_dir)
          FileUtils.mkdir_p(File.join(project_dir, "sig"))
          File.write(File.join(project_dir, "sig", "dry_types.rbs"), dry_types_rbs)
          yield(project_dir, models_dir, cache_root)
        end
      end
    end

    it "recomputes the alias table when a watched source file's content changes between processes" do
      with_project do |project_dir, models_dir, cache_root|
        types_path = File.join(models_dir, "types.rb")

        # Process 1: Email resolves to String. This warms the on-disk cache.
        File.write(types_path, types_module(underlying: "String"))
        first, first_store = run_dry_types(project_dir: project_dir, models_dir: models_dir, cache_root: cache_root)
        expect(first.fetch("Types::Email")).to eq("String")
        expect(producer_stats(first_store)[:writes]).to be >= 1

        # Change Email's underlying class. The watched glob's digest moves, so a fresh process must recompute
        # and publish the NEW table rather than serving last session's "String".
        File.write(types_path, types_module(underlying: "Integer"))
        second, second_store = run_dry_types(project_dir: project_dir, models_dir: models_dir, cache_root: cache_root)
        expect(second.fetch("Types::Email")).to eq("Integer")
        expect(producer_stats(second_store)[:misses]).to be >= 1
        expect(producer_stats(second_store)[:hits]).to eq(0)
      end
    end

    it "recomputes when a new dry-types source file is ADDED under the watched tree" do
      with_project do |project_dir, models_dir, cache_root|
        # This is the case an IoBoundary read-history descriptor alone would miss: the added file was never
        # read by the prior process, so only the `watch:` glob (which re-globs the whole tree) catches it.
        File.write(File.join(models_dir, "types.rb"), <<~RUBY)
          module Types
            include Dry.Types()
          end
        RUBY
        first, = run_dry_types(project_dir: project_dir, models_dir: models_dir, cache_root: cache_root)
        expect(first).not_to have_key("Types::Email")

        # A brand-new file the first process never read. Its composition must appear after invalidation.
        File.write(File.join(models_dir, "more_types.rb"), <<~RUBY)
          module Types
            include Dry.Types()
            Email = String.constrained(min_size: 1)
          end
        RUBY
        second, second_store = run_dry_types(project_dir: project_dir, models_dir: models_dir, cache_root: cache_root)
        expect(second.fetch("Types::Email")).to eq("String")
        expect(producer_stats(second_store)[:misses]).to be >= 1
        expect(producer_stats(second_store)[:hits]).to eq(0)
      end
    end

    it "serves the alias table from cache on an unchanged second process (no re-scan)" do
      with_project do |project_dir, models_dir, cache_root|
        File.write(File.join(models_dir, "types.rb"), types_module(underlying: "String"))

        _first, first_store = run_dry_types(project_dir: project_dir, models_dir: models_dir, cache_root: cache_root)
        expect(producer_stats(first_store)[:misses]).to be >= 1
        expect(producer_stats(first_store)[:writes]).to be >= 1

        # Nothing changed: the second process must validate the watch digest and serve the cached table — a
        # HIT, never a recompute — while still returning the correct value.
        second, second_store = run_dry_types(project_dir: project_dir, models_dir: models_dir, cache_root: cache_root)
        expect(producer_stats(second_store)[:hits]).to be >= 1
        expect(producer_stats(second_store)[:misses]).to eq(0)
        expect(second.fetch("Types::Email")).to eq("String")
      end
    end
  end

  # Runs the plugin against a single-file project and returns the `:dry_type_aliases` fact value (or `nil` if
  # the plugin didn't publish it). Captures the per-run `Plugin::Services` instance via `wrap_original` so we
  # can read the fact store after `prepare(services)` ran — same pattern as the rigor-rails-routes integration spec.
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
