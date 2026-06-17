# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "rigor/protection/test_suite_oracle"

# ADR-70 — the dynamic (test-suite) kill oracle. The runner is injected so the
# kill logic + the file restore guarantee are exercised without shelling out.
RSpec.describe Rigor::Protection::TestSuiteOracle do
  it "is green when the runner reports the suite passed" do
    oracle = described_class.new(command: %w[noop], runner: ->(_) { true })
    expect(oracle.green?).to be(true)
  end

  it "is not green when the runner reports failure" do
    oracle = described_class.new(command: %w[noop], runner: ->(_) { false })
    expect(oracle.green?).to be(false)
  end

  it "kills a mutant when the suite goes red, with the mutant on disk during the run" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "f.rb")
      File.write(path, "original")
      on_disk_during_run = nil
      oracle = described_class.new(command: %w[noop], runner: lambda { |_|
        on_disk_during_run = File.read(path)
        false # red == killed
      })

      killed = oracle.killed?(path: path, original: "original", mutant_source: "mutant")

      expect(killed).to be(true)
      expect(on_disk_during_run).to eq("mutant")
      expect(File.read(path)).to eq("original") # restored
    end
  end

  it "does not kill when the suite stays green, and restores the file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "f.rb")
      File.write(path, "original")
      oracle = described_class.new(command: %w[noop], runner: ->(_) { true })

      killed = oracle.killed?(path: path, original: "original", mutant_source: "mutant")

      expect(killed).to be(false)
      expect(File.read(path)).to eq("original")
    end
  end

  it "restores the file even when the runner raises" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "f.rb")
      File.write(path, "original")
      oracle = described_class.new(command: %w[noop], runner: ->(_) { raise "boom" })

      expect do
        oracle.killed?(path: path, original: "original", mutant_source: "mutant")
      end.to raise_error("boom")
      expect(File.read(path)).to eq("original")
    end
  end
end
