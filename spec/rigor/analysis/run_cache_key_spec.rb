# frozen_string_literal: true

require "spec_helper"
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
  end

  describe "inputs that do not change the key" do
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
