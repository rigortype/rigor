# frozen_string_literal: true

require "rigor/language_server/debouncer"

RSpec.describe Rigor::LanguageServer::Debouncer do
  let(:debouncer) { described_class.new }

  describe "#schedule" do
    it "runs the block asynchronously when delay is 0" do
      calls = []
      debouncer.schedule(:k, delay: 0) { calls << :run }
      debouncer.flush!

      expect(calls).to eq([:run])
    end

    it "honours the delay before firing" do
      mutex = Mutex.new
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      fired_at = nil
      debouncer.schedule(:k, delay: 0.05) do
        mutex.synchronize { fired_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end
      debouncer.flush!

      expect(fired_at).not_to be_nil
      expect(fired_at - started_at).to be >= 0.04 # tolerate scheduler jitter
    end

    it "cancels the prior task when re-scheduled for the same key" do
      calls = []
      debouncer.schedule(:k, delay: 0.02) { calls << :first }
      sleep 0.005
      debouncer.schedule(:k, delay: 0) { calls << :second }
      debouncer.flush!

      expect(calls).to eq([:second])
    end

    it "keeps tasks for different keys independent" do
      calls = []
      debouncer.schedule(:a, delay: 0) { calls << :a }
      debouncer.schedule(:b, delay: 0) { calls << :b }
      debouncer.flush!

      expect(calls).to contain_exactly(:a, :b)
    end
  end

  describe "#cancel_all" do
    it "prevents any pending tasks from running their block" do
      ran = false
      debouncer.schedule(:k, delay: 0.5) { ran = true }
      debouncer.cancel_all

      # Wait past the delay window to confirm cancellation stuck.
      sleep 0.05
      expect(ran).to be(false)
    end
  end

  describe "#pending_size" do
    it "reports the number of in-flight tasks" do
      debouncer.schedule(:k1, delay: 0.5) { :noop }
      debouncer.schedule(:k2, delay: 0.5) { :noop }

      expect(debouncer.pending_size).to eq(2)
      debouncer.cancel_all
    end
  end
end
