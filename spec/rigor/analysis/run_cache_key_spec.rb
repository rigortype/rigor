# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# Plain data in, key out: `RunCacheKey.descriptor` is a function of a configuration, a path set and two flags, and the
# runner and the engine-free probe both build the key through it. A key that ignores an input the answer depends on
# serves stale diagnostics; one that sees an input it does not depend on costs the warm run its hit. Each example
# changes one input and compares the key string.
RSpec.describe Rigor::Analysis::RunCacheKey do
  def key(configuration: Rigor::Configuration.new, files: %w[a.rb b.rb], explain: false, rbs: [], units: nil,
          roots: nil)
    descriptor = described_class.descriptor(configuration: configuration, files: files, explain: explain,
                                            rbs_config_entries: rbs, template_units_digest: units)
    descriptor = described_class.with_roots(descriptor, roots) if roots
    descriptor.cache_key_for(producer_id: described_class::RUN_DIAGNOSTICS_PRODUCER_ID)
  end

  let(:base) { key }

  describe "inputs that change the key" do
    it "the analysed-path set: a file added or removed" do
      expect(key(files: %w[a.rb b.rb c.rb])).not_to eq(base)
      expect(key(files: %w[a.rb])).not_to eq(base)
    end

    it "`--explain`" do
      expect(key(explain: true)).not_to eq(base)
    end

    it "a resolved configuration value" do
      older = Rigor::Configuration.new({ "target_ruby" => "3.3" })
      newer = Rigor::Configuration.new({ "target_ruby" => "3.4" })

      expect(key(configuration: newer)).not_to eq(key(configuration: older))
    end

    it "the RBS config slots the loader reports" do
      entry = described_class.config_entry("rbs.virtual_rbs", "synthesised")

      expect(key(rbs: [entry])).not_to eq(base)
    end

    it "the template units' digest, and only when there is one" do
      expect(key(units: "abc")).not_to eq(base)
      expect(key(units: "abd")).not_to eq(key(units: "abc"))
    end

    it "the analysis roots, as written and in the order written (the diagnostics key only)" do
      expect(key(roots: %w[lib])).not_to eq(base)
      expect(key(roots: %w[lib extra])).not_to eq(key(roots: %w[lib]))
      expect(key(roots: %w[./lib])).not_to eq(key(roots: %w[lib]))
      expect(key(roots: %w[b a])).not_to eq(key(roots: %w[a b]))
    end

    it "the bytes of the Bundler lockfile, and its appearing" do
      Dir.mktmpdir("rigor-run-key") do |dir|
        lock = File.join(dir, "Gemfile.lock")
        configuration = Rigor::Configuration.new({ "bundler" => { "lockfile" => lock } })
        absent = key(configuration: configuration)
        File.write(lock, "GEM\n")
        present = key(configuration: configuration)
        File.write(lock, "GEM\n  specs:\n")

        expect(present).not_to eq(absent)
        expect(key(configuration: configuration)).not_to eq(present)
      end
    end

    it "the bytes of the `rbs_collection` lockfile, and its appearing" do
      Dir.mktmpdir("rigor-run-key") do |dir|
        lock = File.join(dir, "rbs_collection.lock.yaml")
        configuration = Rigor::Configuration.new({ "rbs_collection" => { "lockfile" => lock } })
        absent = key(configuration: configuration)
        File.write(lock, "gems: []\n")
        present = key(configuration: configuration)
        File.write(lock, "gems: [x]\n")

        expect(present).not_to eq(absent)
        expect(key(configuration: configuration)).not_to eq(present)
      end
    end

    it "the setup hint read off the working directory (an `rbs_collection.yaml` with no lockfile)" do
      Dir.mktmpdir("rigor-run-key") do |dir|
        Dir.chdir(dir) do
          without = key
          File.write("rbs_collection.yaml", "sources: []\n")

          expect(key).not_to eq(without)
        end
      end
    end

    it "an opted-in gem's `(name, version, mode)` row" do
      entry = lambda { |version|
        Rigor::Cache::Descriptor::DependencyEntry.new(gem_name: "g", gem_version: version, mode: :full)
      }
      resolver = Rigor::Analysis::DependencySourceInference::GemResolver
      allow(resolver).to receive(:dependency_entries).and_return([entry.call("1")], [entry.call("2")])

      expect(key).not_to eq(key)
    end

    it "the shadow harness being on, whatever the variable's value" do
      old = ENV.fetch("RIGOR_SHADOW_RULE_WALK", nil)
      without = key
      ENV["RIGOR_SHADOW_RULE_WALK"] = "0"

      expect(key).not_to eq(without)
    ensure
      old.nil? ? ENV.delete("RIGOR_SHADOW_RULE_WALK") : ENV["RIGOR_SHADOW_RULE_WALK"] = old
    end

    it "the engine source identity, and a version-pinned tree carrying none" do
      entry = ->(identity) { Rigor::Cache::Descriptor::ConfigEntry.new(key: "engine-source", value_hash: identity) }
      allow(Rigor::Cache::EngineSource).to receive(:key_config_entries)
        .and_return([entry.call("a")], [entry.call("b")], [])

      expect([key, key, key].uniq.size).to eq(3)
    end

    it "the `rbs` gem's version" do
      gem = ->(version) { Rigor::Cache::Descriptor::GemEntry.new(name: "rbs", requirement: ">= 0", locked: version) }
      allow(Rigor::Cache::RbsDescriptor).to receive(:rbs_gem_entry).and_return(gem.call("1.0.0"), gem.call("1.0.1"))

      expect(key).not_to eq(key)
    end

    it "a configuration key other than `target_ruby:`" do
      expect(key(configuration: Rigor::Configuration.new({ "disable" => ["call.undefined-method"] }))).not_to eq(base)
      expect(key(configuration: Rigor::Configuration.new({ "libraries" => ["set"] }))).not_to eq(base)
    end
  end

  describe "inputs that do not change the key" do
    it "the directory an auto-detected lockfile lives in (content only, so a moved checkout still hits)" do
      Dir.mktmpdir("rigor-run-key") do |dir|
        keys = %w[one two].map do |name|
          FileUtils.mkdir_p(File.join(dir, name))
          File.write(File.join(dir, name, "Gemfile.lock"), "GEM\n")
          Dir.chdir(File.join(dir, name)) { key }
        end

        expect(keys.uniq.size).to eq(1)
      end
    end

    it "an absent lockfile having its own value, distinct from an empty one" do
      Dir.mktmpdir("rigor-run-key") do |dir|
        lock = File.join(dir, "Gemfile.lock")
        configuration = Rigor::Configuration.new({ "bundler" => { "lockfile" => lock } })
        absent = key(configuration: configuration)
        File.write(lock, "")

        expect(key(configuration: configuration)).not_to eq(absent)
      end
    end

    it "no setup hint, no opted-in gem, no harness and a version-pinned tree each adding no slot" do
      allow(Rigor::Cache::EngineSource).to receive(:key_config_entries).and_return([])
      descriptor = described_class.descriptor(configuration: Rigor::Configuration.new, files: %w[a.rb],
                                              explain: false, rbs_config_entries: [])

      expect(descriptor.configs.map(&:key)).not_to include("rbs_collection.setup_hint", "shadow-harness",
                                                           "engine-source")
      expect(descriptor.dependencies).to eq([])
    end

    it "the order the files are listed in" do
      expect(key(files: %w[b.rb a.rb])).to eq(base)
    end

    it "the bytes of an analysed file (dependency validation catches those, not the key)" do
      Dir.mktmpdir("rigor-run-key") do |dir|
        file = File.join(dir, "a.rb")
        File.write(file, "x = 1\n")
        before = key(files: [file])
        File.write(file, "x = 22\n")

        expect(key(files: [file])).to eq(before)
      end
    end

    it "an absent template-units digest, which contributes no slot" do
      expect(key(units: nil)).to eq(base)
    end

    it "the roots when the key is the effects sidecar's (it is built without them)" do
      expect(described_class.descriptor(configuration: Rigor::Configuration.new, files: %w[a.rb b.rb], explain: false,
                                        rbs_config_entries: []).configs.map(&:key)).not_to include("roots")
    end

    it "a nil descriptor stays nil through `with_roots`" do
      expect(described_class.with_roots(nil, %w[lib])).to be_nil
    end
  end
end
