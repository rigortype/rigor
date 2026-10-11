# frozen_string_literal: true

require "rigor/analysis/dependency_source_inference"

RSpec.describe Rigor::Analysis::DependencySourceInference::Index do
  describe "EMPTY" do
    it "is frozen with no resolved gems and no unresolvable entries" do
      expect(described_class::EMPTY).to be_frozen
      expect(described_class::EMPTY.resolved_gems).to eq([])
      expect(described_class::EMPTY.unresolvable).to eq([])
      expect(described_class::EMPTY.budget_exceeded).to eq([])
      expect(described_class::EMPTY).to be_empty
    end
  end

  describe "#budget_exceeded (slice 4)" do
    it "stores the gem names whose Walker run hit the budget cap" do
      index = described_class.new(budget_exceeded: %w[rack faraday])

      expect(index.budget_exceeded).to eq(%w[rack faraday])
      expect(index.budget_exceeded).to be_frozen
    end

    it "defaults to an empty array when no gem tripped" do
      expect(described_class.new.budget_exceeded).to eq([])
    end
  end

  describe "#class_to_gem (slice 5b β budget reverse index)" do
    it "stores the per-class owning gem" do
      index = described_class.new(class_to_gem: { "Rack::Request" => "rack", "Faraday::Connection" => "faraday" })

      expect(index.gem_for("Rack::Request")).to eq("rack")
      expect(index.gem_for("Faraday::Connection")).to eq("faraday")
      expect(index.gem_for("Unknown")).to be_nil
    end

    it "defaults to an empty hash" do
      expect(described_class.new.class_to_gem).to eq({})
      expect(described_class.new.gem_for("Anything")).to be_nil
    end
  end

  describe "#budget_overrun_strategy (slice 5b)" do
    it "defaults to :walker_cap" do
      expect(described_class.new.budget_overrun_strategy).to eq(:walker_cap)
    end

    it "accepts :dependency_silence" do
      expect(described_class.new(budget_overrun_strategy: :dependency_silence).budget_overrun_strategy)
        .to eq(:dependency_silence)
    end
  end

  describe "#mode_for / #full_mode? (ADR-10 slice 5c)" do
    it "chains class_to_gem and gem_modes to expose the per-class mode" do
      index = described_class.new(
        class_to_gem: { "Rack::Request" => "rack", "Faraday::Connection" => "faraday" },
        gem_modes: { "rack" => :when_missing, "faraday" => :full }
      )

      expect(index.mode_for("Rack::Request")).to eq(:when_missing)
      expect(index.mode_for("Faraday::Connection")).to eq(:full)
    end

    it "returns nil for classes owned by no listed gem" do
      index = described_class.new(gem_modes: { "rack" => :full })

      expect(index.mode_for("Unknown")).to be_nil
      expect(index).not_to be_full_mode("Unknown")
    end

    it "#full_mode? is true exactly when the owning gem's mode is :full" do
      index = described_class.new(
        class_to_gem: { "Rack" => "rack", "Faraday" => "faraday" },
        gem_modes: { "rack" => :when_missing, "faraday" => :full }
      )

      expect(index.full_mode?("Faraday")).to be true
      expect(index.full_mode?("Rack")).to be false
    end
  end

  describe "#contribution_for" do
    it "returns nil for any (class_name, method_name) when no catalog is supplied" do
      index = described_class.new

      expect(index.contribution_for(class_name: "Foo", method_name: :bar)).to be_nil
    end

    it "returns the recorded kind when the catalog has a matching entry" do
      catalog = { ["Foo", :bar] => :instance, ["Foo", :baz] => :singleton }
      index = described_class.new(method_catalog: catalog)

      # Walker::CatalogEntry is the post-normalization shape; bare-Symbol catalog values are accepted at construction
      # and normalized into the same shape internally.
      expect(index.contribution_for(class_name: "Foo", method_name: :bar).kind).to eq(:instance)
      expect(index.contribution_for(class_name: "Foo", method_name: :baz).kind).to eq(:singleton)
      expect(index.contribution_for(class_name: "Foo", method_name: :missing)).to be_nil
    end
  end

  describe "#empty?" do
    it "is true when no resolved gems are present" do
      expect(described_class.new).to be_empty
    end

    it "is false once a resolved gem is registered, even with no method facts yet" do
      resolver = Rigor::Analysis::DependencySourceInference::GemResolver
      resolved = resolver::Resolved.new(
        gem_name: "rack", version: "1.0.0", gem_dir: "/tmp/rack", mode: :when_missing, roots: %w[lib]
      )
      index = described_class.new(resolved_gems: [resolved])

      expect(index).not_to be_empty
      expect(index.resolved_gems).to eq([resolved])
    end
  end

  describe "#cache_descriptor" do
    let(:resolver) { Rigor::Analysis::DependencySourceInference::GemResolver }

    def resolved(name:, version:, mode:)
      resolver::Resolved.new(
        gem_name: name, version: version, gem_dir: "/tmp/#{name}", mode: mode, roots: %w[lib]
      )
    end

    it "is empty for the EMPTY index" do
      descriptor = described_class::EMPTY.cache_descriptor
      expect(descriptor.dependencies).to eq([])
    end

    it "lifts every resolved gem into a DependencyEntry row" do
      index = described_class.new(
        resolved_gems: [
          resolved(name: "rack", version: "3.0.0", mode: :when_missing),
          resolved(name: "faraday", version: "2.7.0", mode: :full)
        ]
      )

      rows = index.cache_descriptor.dependencies
      expect(rows).to contain_exactly(
        Rigor::Cache::Descriptor::DependencyEntry.new(
          gem_name: "rack", gem_version: "3.0.0", mode: :when_missing
        ),
        Rigor::Cache::Descriptor::DependencyEntry.new(
          gem_name: "faraday", gem_version: "2.7.0", mode: :full
        )
      )
    end

    it "produces a different cache key when a resolved gem's version bumps" do
      before = described_class.new(
        resolved_gems: [resolved(name: "rack", version: "3.0.0", mode: :when_missing)]
      )
      after = described_class.new(
        resolved_gems: [resolved(name: "rack", version: "3.1.0", mode: :when_missing)]
      )

      expect(before.cache_descriptor.cache_key_for(producer_id: "p"))
        .not_to eq(after.cache_descriptor.cache_key_for(producer_id: "p"))
    end

    it "ignores unresolvable entries — they have no version to key on" do
      unresolvable = resolver::Unresolvable.new(gem_name: "ghost", reason: :not_in_bundle)
      index = described_class.new(unresolvable: [unresolvable])

      expect(index.cache_descriptor.dependencies).to eq([])
    end
  end

  # Issue #1814 — what each walked gem's walk read, and the one question the readers ask: has every file that could
  # refine this module been read?
  describe "#fully_read_module?" do
    def reading(gem_name, modules, fully_read:)
      described_class::Reading.new(gem_name: gem_name, modules: Set.new(modules), fully_read: fully_read)
    end

    it "is true for a module a gem named and read in full, and false for one nothing walked names" do
      index = described_class.new(readings: [reading("rainbow", %w[Rainbow Rainbow::Presenter], fully_read: true)])

      expect(index.fully_read_module?("Rainbow")).to be(true)
      expect(index.fully_read_module?("Rainbow::Presenter")).to be(true)
      expect(index.fully_read_module?("Other")).to be(false)
      expect(described_class::EMPTY.fully_read_module?("Rainbow")).to be(false)
    end

    it "is false for a module a gem named and did not read in full" do
      index = described_class.new(readings: [reading("cut", %w[Cut], fully_read: false)])

      expect(index.fully_read_module?("Cut")).to be(false)
    end

    it "is false for a module any gem that names it did not read in full, and true when each did" do
      whole = reading("base", %w[Shared Only], fully_read: true)
      cut = reading("ext", %w[Shared], fully_read: false)
      whole_ext = reading("ext", %w[Shared], fully_read: true)

      mixed = described_class.new(readings: [whole, cut])
      both = described_class.new(readings: [whole, whole_ext])

      expect([mixed.fully_read_module?("Shared"), mixed.fully_read_module?("Only")]).to eq([false, true])
      expect(both.fully_read_module?("Shared")).to be(true)
    end

    it "keeps the readings beside the refinement table" do
      readings = [reading("a", %w[A], fully_read: true)]
      index = described_class.new(refinements: { "String" => { shout: ["A"] } }, readings: readings)

      expect(index.readings).to eq(readings)
      expect(index.refinements).to eq("String" => { shout: ["A"] })
    end
  end
end
