# frozen_string_literal: true

require "rigor/language_server/synchronized_writer"

RSpec.describe Rigor::LanguageServer::SynchronizedWriter do
  let(:inner) do
    Class.new do
      attr_reader :payloads

      def initialize
        @payloads = []
        @write_mutex = Mutex.new
      end

      def write(payload)
        # Simulate interleaving-prone work — two `<<` operations
        # with a tiny gap. Without an outer mutex this would
        # produce torn output under concurrent writers.
        @write_mutex.synchronize { @payloads << [:start, payload] }
        sleep 0.001
        @write_mutex.synchronize { @payloads << [:end, payload] }
      end

      def close; end
    end.new
  end

  let(:writer) { described_class.new(inner) }

  it "forwards #write to the inner writer" do
    writer.write({ method: "x" })

    expect(inner.payloads).to include([:start, { method: "x" }])
  end

  it "serialises concurrent writes from multiple threads (no interleaving)" do
    threads = Array.new(8) do |i|
      Thread.new { writer.write({ id: i }) }
    end
    threads.each(&:join)

    # If `write` were unsynchronised, the per-call pair
    # `[:start, msg]` then `[:end, msg]` could be interleaved
    # with another writer's pair. With the mutex, every pair is
    # contiguous in the payloads list.
    inner.payloads.each_slice(2) do |start_pair, end_pair|
      expect(start_pair[0]).to eq(:start)
      expect(end_pair[0]).to eq(:end)
      expect(start_pair[1]).to eq(end_pair[1])
    end
  end
end
