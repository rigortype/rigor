# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-129 WD3 / WD5 shape 2 / issue #2814 — the two per-thread output sinks plugin code writes while a file is analysed
# (`Plugin::IoBoundary.attributing`, `Analysis::RunDisclosureCredit.collect`) are Resources: an append refuses every
# open capture, so a `type_of` memo can never store an answer whose hit would skip the append a miss made. A read
# from inside an `Enumerator` (another fiber, which has typing state of its own) refuses the installing fiber's
# captures too.
RSpec.describe "plugin attribution sinks as typing-state Resources (#2814)" do
  let(:state) { Rigor::TypingState.current }
  let(:tmpdir) { Dir.mktmpdir("rigor-sink-resource-spec-") }
  let(:path) { File.join(tmpdir, "data.txt").tap { |file| File.write(file, "hello") } }
  let(:boundary) do
    Rigor::Plugin::IoBoundary.new(
      policy: Rigor::Plugin::TrustPolicy.new(allowed_read_roots: [tmpdir]), plugin_id: "demo"
    )
  end

  after { FileUtils.rm_rf(tmpdir) }

  # Whether a capture opened around the block was refused.
  def refused_around
    state.open_capture
    begin
      yield
    ensure
      refused, = state.close_capture
    end
    refused
  end

  describe Rigor::Plugin::IoBoundary do
    it "refuses a capture open around a boundary read that lands in the sink" do
      reads = []
      refused = described_class.attributing(reads) { refused_around { boundary.read_file(path) } }
      expect(refused).to be(true)
      expect(reads).not_to be_empty
    end

    it "refuses the installing fiber's capture for a read made inside an Enumerator" do
      reads = []
      refused = described_class.attributing(reads) do
        refused_around { Enumerator.new { |y| y << boundary.read_file(path) }.next }
      end
      expect(refused).to be(true)
      expect(reads).not_to be_empty
    end

    it "refuses a capture for a boundary read with no sink installed" do
      expect(refused_around { boundary.read_file(path) }).to be(true)
    end

    it "leaves a capture around plugin-free work unrefused (control)" do
      expect(described_class.attributing([]) { refused_around { File.read(path) } }).to be(false)
    end
  end

  describe Rigor::Analysis::RunDisclosureCredit do
    let(:plugin) { Object.new }
    let(:record) { { key: :k, diagnostics: [:row] } }

    before { allow(described_class).to receive(:boundary_rows).and_return([]) }

    it "refuses a capture open around a registration that lands in the sink" do
      refused = nil
      records = described_class.collect do
        refused = refused_around { described_class.attribute(plugin, record) }
      end
      expect(refused).to be(true)
      expect(records.size).to eq(1)
    end

    it "refuses the installing fiber's capture for a registration made inside an Enumerator" do
      refused = nil
      records = described_class.collect do
        refused = refused_around { Enumerator.new { |y| y << described_class.attribute(plugin, record) }.next }
      end
      expect(refused).to be(true)
      expect(records.size).to eq(1)
    end

    it "leaves a capture with no registration unrefused (control)" do
      refused = nil
      described_class.collect { refused = refused_around { nil } }
      expect(refused).to be(false)
    end
  end
end
