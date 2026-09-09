# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/plugin_gap_advisory"

RSpec.describe Rigor::PluginGapAdvisory do
  let(:root) { Dir.mktmpdir }

  after { FileUtils.remove_entry(root) }

  # `direct:` defaults to the whole spec list, so an arm that does not care about the distinction reads as
  # before; pass it explicitly to model a transitive gem.
  def write_lock(*gems, direct: gems)
    specs = gems.map { |gem| "    #{gem} (1.0.0)\n" }.join
    deps = direct.map { |gem| "  #{gem}\n" }.join
    File.write(
      File.join(root, "Gemfile.lock"),
      "GEM\n  specs:\n#{specs}\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n#{deps}"
    )
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

    # `minitest` and `i18n` are activesupport's dependencies, so they sit in nearly every Rails lock. Advising
    # on them fires on a project that never chose them.
    it "ignores a modelled gem that is only in the resolved graph" do
      write_lock("sidekiq", "minitest", "i18n", direct: ["sidekiq"])

      expect(described_class.gaps(project_root: root, plugins: []).map(&:plugin_gem)).to eq(["rigor-sidekiq"])
    end

    it "returns nothing when the lockfile declares no dependencies at all" do
      write_lock("sidekiq", "minitest", direct: [])

      expect(described_class.gaps(project_root: root, plugins: [])).to be_empty
    end

    # A Rails app's Gemfile says `rails`; without the umbrella table the whole family would go unmentioned.
    it "expands an umbrella dependency to the gems its members model" do
      # Only the umbrella is in the graph at all, so this arm fails on any read that skips the expansion.
      write_lock("rails", direct: ["rails"])

      expect(described_class.gaps(project_root: root, plugins: []).map(&:plugin_gem))
        .to include("rigor-activerecord", "rigor-railties")
    end
  end

  describe ".unconfigured?" do
    it "is true when no plugin modelling any locked gem is enabled" do
      write_lock("sidekiq", "activerecord")

      expect(described_class.unconfigured?(project_root: root, plugins: [])).to be(true)
    end

    # The `:fail` is the branch a false positive costs the most in: it exits non-zero on a project that is
    # correctly configured. A lock with no `DEPENDENCIES` section must never reach it.
    it "is false when the only modelled gems are transitive" do
      write_lock("minitest", "i18n", direct: [])

      expect(described_class.unconfigured?(project_root: root, plugins: [])).to be(false)
    end

    it "is false once one of them is enabled, even with others still missing" do
      write_lock("sidekiq", "activerecord")

      expect(described_class.unconfigured?(project_root: root, plugins: ["rigor-activerecord"])).to be(false)
      expect(described_class.gaps(project_root: root, plugins: ["rigor-activerecord"]).map(&:plugin_gem))
        .to eq(["rigor-sidekiq"])
    end
  end
end
