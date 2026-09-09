# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/plugin_gap_advisory"

RSpec.describe Rigor::PluginGapAdvisory do
  let(:root) { Dir.mktmpdir }

  after { FileUtils.remove_entry(root) }

  def write_lock(*gems)
    specs = gems.map { |gem| "    #{gem} (1.0.0)\n" }.join
    File.write(File.join(root, "Gemfile.lock"), "GEM\n  specs:\n#{specs}\nPLATFORMS\n  ruby\n")
  end

  describe ".gaps" do
    it "names the bundled plugin modelling a locked gem that is not enabled" do
      write_lock("sidekiq")

      gaps = described_class.gaps(project_root: root, plugins: [])

      expect(gaps.map(&:plugin_gem)).to include("rigor-sidekiq")
      expect(gaps.find { |gap| gap.plugin_gem == "rigor-sidekiq" }.locked_gems).to eq(["sidekiq"])
    end

    # The gem name is not derivable from the plugin name — ADR-96's `factory_bot` case, the reason
    # `target_gems:` is a declared field rather than a convention.
    it "matches a plugin whose gem name differs from its id" do
      write_lock("factory_bot")

      expect(described_class.gaps(project_root: root, plugins: []).map(&:plugin_gem))
        .to eq(["rigor-factorybot"])
    end

    it "skips a plugin the project already enabled, in either spelling" do
      write_lock("sidekiq")

      expect(described_class.gaps(project_root: root, plugins: ["rigor-sidekiq"])).to be_empty
      expect(described_class.gaps(project_root: root, plugins: [{ "gem" => "rigor-sidekiq" }])).to be_empty
      expect(described_class.gaps(project_root: root, plugins: [{ "id" => "sidekiq" }])).to be_empty
    end

    it "returns nothing for a project with no Gemfile.lock" do
      expect(described_class.gaps(project_root: root, plugins: [])).to be_empty
    end

    it "returns nothing when no locked gem has a bundled plugin" do
      write_lock("some-gem-rigor-does-not-model")

      expect(described_class.gaps(project_root: root, plugins: [])).to be_empty
    end
  end

  describe ".unconfigured?" do
    it "is true when no plugin modelling any locked gem is enabled" do
      write_lock("sidekiq", "activerecord")

      expect(described_class.unconfigured?(project_root: root, plugins: [])).to be(true)
    end

    it "is false once one of them is enabled, even with others still missing" do
      write_lock("sidekiq", "activerecord")

      expect(described_class.unconfigured?(project_root: root, plugins: ["rigor-activerecord"])).to be(false)
      expect(described_class.gaps(project_root: root, plugins: ["rigor-activerecord"]).map(&:plugin_gem))
        .to eq(["rigor-sidekiq"])
    end
  end
end
