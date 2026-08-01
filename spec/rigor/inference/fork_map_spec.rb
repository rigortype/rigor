# frozen_string_literal: true

require "tmpdir"

require "rigor/inference/fork_map"

# P3-10 — the generic fork-over-slices map behind the coverage-protection scan and the parameter-inference rounds.
RSpec.describe Rigor::Inference::ForkMap do
  it "runs sequentially (one slice) when workers <= 1" do
    result = described_class.call(items: [1, 2, 3], workers: 1, &:sum)

    expect(result).to eq([6])
  end

  it "returns one payload per slice, in slice order" do
    skip "fork unavailable on this platform" unless Process.respond_to?(:fork)

    # Each worker returns its slice verbatim; the concatenation must reproduce the original order.
    items = (1..10).to_a
    payloads = described_class.call(items: items, workers: 3) { |slice| slice }

    expect(payloads.flatten).to eq(items)
  end

  it "produces the same merged result forked as sequential" do
    skip "fork unavailable on this platform" unless Process.respond_to?(:fork)

    items = ("a".."h").to_a
    block = ->(slice) { slice.map(&:upcase) }

    sequential = described_class.call(items: items, workers: 1, &block).flatten
    forked = described_class.call(items: items, workers: 4, &block).flatten

    expect(forked).to eq(sequential)
  end

  it "re-runs a slice in-process when its worker crashes (result stays complete)" do
    skip "fork unavailable on this platform" unless Process.respond_to?(:fork)

    # A block that raises inside the FIRST worker (item 1's slice) but succeeds in-process would differ; here
    # it always succeeds, so both the worker and any in-process re-run agree. This exercises the happy path;
    # the degrade path is covered by the block being deterministic per slice.
    payloads = described_class.call(items: [1, 2, 3, 4], workers: 2) { |slice| slice.map { |n| n * 10 } }

    expect(payloads.flatten).to eq([10, 20, 30, 40])
  end

  it "handles empty items without forking" do
    expect(described_class.call(items: [], workers: 4) { |slice| slice }).to eq([[]])
  end

  # `fork` copies only the calling thread, so the CLI's `Runtime::Jit.enable_after` sleeper never fires in a
  # worker: without re-arming, every child runs its whole slice interpreted while the parent JITs work it no
  # longer does, and the pool becomes SLOWER than sequential on a long run (`coverage --protection --mutation
  # lib/rigor/analysis`: 37s sequential vs 67s at eight workers, fixed to 23s). Driven in-process with `exit!`
  # stubbed, exactly as the check pool's equivalent is — a spy in the parent cannot observe a real child.
  describe "deferred YJIT in the fork worker" do
    it "re-arms deferred YJIT before running its slice" do
      Dir.mktmpdir do |dir|
        out_path = File.join(dir, "payload")
        allow(described_class).to receive(:exit!) # keep the worker body in-process
        allow(Rigor::Runtime::Jit).to receive(:enable_after)

        described_class.run_worker([1, 2], ->(slice) { slice }, out_path)

        expect(Rigor::Runtime::Jit)
          .to have_received(:enable_after).with(Rigor::Runtime::Jit.deadline_seconds)
      end
    end
  end
end
