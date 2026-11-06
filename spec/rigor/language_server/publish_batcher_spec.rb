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

  describe "a SystemStackError raised from C (no backtrace) in on_batch (#2455)" do
    # `raise` stamps a backtrace on any exception, so the C-raised shape (no backtrace) is a subclass that reports none.
    let(:c_overflow_class) { Class.new(SystemStackError) { def backtrace = nil } }

    def c_overflow = c_overflow_class.new("stack level too deep")

    it "retries a multi-key batch key by key, dropping the key that overflows and publishing the others" do
      calls = []
      on_batch = lambda do |keys|
        raise c_overflow if keys.include?(:deep)

        calls << keys
      end
      batcher = described_class.new(on_batch: on_batch)
      batcher.instance_variable_get(:@pending).push(:deep, :ok)

      batcher.enqueue(:deep)

      expect(calls).to eq([[:ok]])
    end

    it "drops a lone overflowing key and still runs the keys that joined during the round" do
      calls = []
      batcher = nil
      on_batch = lambda do |keys|
        if keys == [:deep]
          batcher.enqueue(:ok)
          raise c_overflow
        end
        calls << keys
      end
      batcher = described_class.new(on_batch: on_batch)

      batcher.enqueue(:deep)

      expect(calls).to eq([[:ok]])
    end

    it "releases the round when on_batch raises something no rescue catches (a guard for the ensure)" do
      calls = []
      first = true
      on_batch = lambda do |keys|
        if first
          first = false
          raise NoMemoryError
        end
        calls << keys
      end
      batcher = described_class.new(on_batch: on_batch)

      expect { batcher.enqueue(:a) }.to raise_error(NoMemoryError)
      batcher.enqueue(:b)

      expect(calls).to eq([[:b]])
    end
  end
end
