# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/incremental_run_slot/write_guard"

# ADR-45 WD2 (#1507) — the write guard's mark on a filesystem with a coarse change-time tick (ext4, tmpfs), which
# a fine-grained macOS APFS run never meets. The clock is coarsened in the spec, so the examples do not depend on
# the filesystem the suite runs on.
RSpec.describe Rigor::Analysis::IncrementalRunSlot::WriteGuard do
  # Not a divisor of a second: a first stamp on a whole second is declined as a filesystem too coarse to wait out.
  let(:tick_ns) { 47_000_000 }
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

  it "takes no mark when the first stamp lands on a whole second, a filesystem too coarse to wait out" do
    device = File.stat(Dir.pwd).dev
    allow(described_class).to receive(:write_stamp).and_return([3_000_000_000, device])
    expect(start).to be_nil
    expect(described_class).to have_received(:write_stamp).once
  end

  it "takes no mark on native Windows, where a change time is the creation time" do
    allow(Gem).to receive(:win_platform?).and_return(true)
    expect(start).to be_nil
  end

  it "refuses the write once the clock reads earlier than the mark" do
    guard = start
    expect(guard.admits?(rows_for("lib/a.rb"))).to be(true)

    allow(described_class).to receive(:write_stamp).and_return([1, File.stat(Dir.pwd).dev])
    expect(guard.admits?(rows_for("lib/a.rb"))).to be(false)
  end

  it "refuses the write when the closing stamp cannot be written" do
    guard = start
    allow(described_class).to receive(:write_stamp).and_return(nil)
    expect(guard.admits?(rows_for("lib/a.rb"))).to be(false)
  end

  # `derived` carries an existence row for every `pre_eval:` entry, and the baseline a content row for the same path
  # when it is outside the analysed files. The row that comes first must not hide the other.
  context "with a `pre_eval:` file that is an existence row and a content row" do
    let(:configuration) do
      Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge({ "paths" => ["lib"],
                                                                      "pre_eval" => ["support/pre.rb"] }))
    end

    before { write("support/pre.rb", "PRE = 1\n") }

    def presence_row(path) = Rigor::Cache::Descriptor::FileEntry.present(path: File.expand_path(path))

    def content_row(path)
      absolute = File.expand_path(path)
      Rigor::Cache::Descriptor::FileEntry.stat(path: absolute, digest: Rigor::Cache::FileDigest.hexdigest(absolute))
    end

    it "refuses the write for an edit after the mark, whichever row comes first" do
      guard = start
      write("support/pre.rb", "PRE = 2\n")
      both = Rigor::Cache::Descriptor.new(files: [presence_row("support/pre.rb"), content_row("support/pre.rb")])
      expect(guard.admits?(Rigor::Cache::Descriptor.new(files: [content_row("support/pre.rb")]))).to be(false)
      expect(guard.admits?(both)).to be(false)
    end
  end

  # A row recorded as the run read carries the instant the run began. On a coarse clock a same-size save after the
  # read keeps the stat tuple, so the row must turn racy for every mtime at or after the mark.
  describe "#mark_racy" do
    def instant_of(descriptor)
      descriptor.files.map { |entry| entry.value.split.last.to_i }
    end

    it "lowers a row's recording instant to the mark, and leaves an earlier one and other rows alone" do
      guard = start
      mark = guard.instance_variable_get(:@started_ns)
      stat = Rigor::Cache::Descriptor::FileEntry.stat(path: File.expand_path("lib/a.rb"), digest: "d" * 64)
      late = Rigor::Cache::Descriptor::FileEntry.new(
        path: "/x", comparator: :stat, value: stat.value.split[0..4].push((mark + 1_000).to_s).join(" ")
      )
      early = Rigor::Cache::Descriptor::FileEntry.new(
        path: "/y", comparator: :stat, value: stat.value.split[0..4].push((mark - 1_000).to_s).join(" ")
      )
      presence = Rigor::Cache::Descriptor::FileEntry.present(path: "/z")
      racy = guard.mark_racy(Rigor::Cache::Descriptor.new(files: [late, early, presence]))
      expect(instant_of(Rigor::Cache::Descriptor.new(files: racy.files.first(2)))).to eq([mark, mark - 1_000])
      expect(racy.files.last).to eq(presence)
    end
  end
end
