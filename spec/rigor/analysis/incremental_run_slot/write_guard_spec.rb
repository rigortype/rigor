# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/incremental_run_slot/write_guard"

# ADR-45 WD2 (#1507) — the write guard's mark on a filesystem with a coarse change-time tick (ext4, tmpfs), which
# a fine-grained macOS APFS run never meets. The clock is coarsened in the spec, so the examples do not depend on
# the filesystem the suite runs on.
RSpec.describe Rigor::Analysis::IncrementalRunSlot::WriteGuard do
  let(:tick_ns) { 50_000_000 }
  let(:cache_root) { File.join(Dir.pwd, ".rigor", "cache") }
  let(:configuration) do
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge({ "paths" => ["lib"] }))
  end

  around do |example|
    Dir.mktmpdir("rigor-write-guard-") do |raw|
      Dir.chdir(File.realpath(raw)) { example.run }
    end
  end

  before do
    stub_const("#{described_class}::TICK_WAIT_LIMIT", 0.5)
    allow(Rigor::Cache::FileDigest).to receive(:ns_of).and_wrap_original do |original, time|
      original.call(time) / tick_ns * tick_ns
    end
    write("lib/a.rb", "class Widget\nend\n")
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def start
    described_class.start(
      configuration: configuration, roots: ["lib"], cache_root: cache_root,
      fingerprint: Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: ["lib"])
    )
  end

  def rows_for(path)
    Rigor::Cache::Descriptor.new(
      files: [Rigor::Cache::Descriptor::FileEntry.stat(path: path, digest: Rigor::Cache::FileDigest.hexdigest(path))]
    )
  end

  # Leaves the clock early in a tick, so a write and the stamp that follows it share the tick, as they do on a
  # filesystem whose tick is longer than the gap between them.
  def at_tick_start
    loop do
      break if (Time.now.to_r * 1_000_000_000).to_i % tick_ns < tick_ns / 5

      sleep(0.001)
    end
  end

  it "admits a file saved just before the mark, in the tick of the first stamp" do
    at_tick_start
    write("lib/a.rb", "class Widget\n  def go\n  end\nend\n")
    expect(start.admits?(rows_for("lib/a.rb"))).to be(true)
  end

  it "refuses a file saved right after the mark, in the tick the mark closes" do
    guard = start
    write("lib/a.rb", "class Widget\n  def go\n  end\nend\n")
    expect(guard.admits?(rows_for("lib/a.rb"))).to be(false)
  end

  it "admits a lockfile written just before the mark, and refuses one written right after" do
    at_tick_start
    write("Gemfile.lock", "GEM\n  specs:\n")
    guard = start
    expect(guard.admits?(rows_for("lib/a.rb"))).to be(true)

    write("Gemfile.lock", "GEM\n  specs:\n\n")
    expect(guard.admits?(rows_for("lib/a.rb"))).to be(false)
  end

  it "takes no mark when the change time never ticks within the wait" do
    stub_const("#{described_class}::TICK_WAIT_LIMIT", 0.02)
    device = File.stat(Dir.pwd).dev
    allow(described_class).to receive(:write_stamp).and_return([1, device])
    expect(start).to be_nil
    expect(described_class).to have_received(:write_stamp).at_least(:twice)
  end
end
