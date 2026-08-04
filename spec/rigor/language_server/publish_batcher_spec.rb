# frozen_string_literal: true

require "rigor/language_server/publish_batcher"

RSpec.describe Rigor::LanguageServer::PublishBatcher do
  describe "#enqueue" do
    it "runs on_batch with the deduplicated pending keys" do
      calls = []
      batcher = described_class.new(on_batch: ->(keys) { calls << keys })

      batcher.enqueue(:a)

      expect(calls).to eq([[:a]])
    end

    it "deduplicates keys pending at drain time (the race a concurrent double-enqueue can produce)" do
      calls = []
      batcher = described_class.new(on_batch: ->(keys) { calls << keys })
      # Simulates two threads both appending the SAME key before either drains — `@lock.synchronize` in
      # `#enqueue` only serializes the append + ownership check, so two callers can both land an append
      # before the owner's `#run_batch` drains. Reached here directly (white-box) since provoking the actual
      # race deterministically would require real thread scheduling control.
      batcher.instance_variable_get(:@pending).push(:a, :a)

      batcher.enqueue(:a)

      expect(calls).to eq([[:a]])
    end

    it "does not start a nested round when on_batch itself calls #enqueue — it folds into a follow-up round" do
      calls = []
      batcher = nil
      batcher = described_class.new(
        on_batch: lambda do |keys|
          calls << keys
          batcher.enqueue(:b) if keys == [:a]
        end
      )

      batcher.enqueue(:a)

      expect(calls).to eq([[:a], [:b]])
    end

    it "a call that arrives while a round is running only enqueues — it does not run on_batch itself" do
      calls = []
      entered = false
      batcher = nil
      batcher = described_class.new(
        on_batch: lambda do |keys|
          unless entered
            entered = true
            # Simulates a SECOND thread's `#enqueue(:b)` landing while THIS round (for :a) is still
            # executing — from inside the same call for a deterministic spec, but the code path exercised
            # (append to pending, see `@running` already true, return without touching `on_batch`) is
            # identical to a genuinely concurrent caller.
            batcher.enqueue(:b)
          end
          calls << keys
        end
      )

      batcher.enqueue(:a)

      expect(calls).to eq([[:a], [:b]])
    end

    it "releases ownership after on_batch raises and reports through on_error, so the NEXT round still runs" do
      errors = []
      calls = []
      first_call = true
      batcher = described_class.new(
        on_batch: lambda do |keys|
          if first_call
            first_call = false
            raise "boom"
          end
          calls << keys
        end,
        on_error: ->(e) { errors << e }
      )

      batcher.enqueue(:a)
      batcher.enqueue(:b)

      expect(errors.map(&:message)).to eq(["boom"])
      # A stuck `@running` flag would make this call silently no-op forever instead of running a fresh round.
      expect(calls).to eq([[:b]])
    end

    it "swallows an on_batch exception silently when on_error is not provided" do
      batcher = described_class.new(on_batch: ->(_keys) { raise "boom" })

      expect { batcher.enqueue(:a) }.not_to raise_error
    end
  end
end
