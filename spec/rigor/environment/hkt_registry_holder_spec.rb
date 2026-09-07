# frozen_string_literal: true

require "spec_helper"
require "rigor/environment"

RSpec.describe Rigor::Environment::HktRegistryHolder do
  subject(:holder) { described_class.new }

  it "computes the value once and serves it on every later fetch" do
    calls = 0
    2.times do
      holder.fetch do
        calls += 1
        :registry
      end
    end
    expect(calls).to eq(1)
  end

  it "caches a nil value (a build that legitimately produced nothing is not recomputed)" do
    calls = 0
    2.times do
      holder.fetch do
        calls += 1
        nil
      end
    end
    expect(calls).to eq(1)
  end

  # Issue #776 / #784 — the guarded build is shared across every file in the run; without failure
  # memoization a raising `yield` is retried and re-raised once per file.
  it "memoizes a StandardError and re-raises the original without re-running the block" do
    calls = 0
    boom = ArgumentError.new("unknown keyword: :name_scope")

    expect { holder.fetch { calls += 1; raise boom } }.to raise_error(boom) # rubocop:disable Style/Semicolon
    expect { holder.fetch { calls += 1; raise "a different error" } }.to raise_error(boom) # rubocop:disable Style/Semicolon

    expect(calls).to eq(1)
  end

  it "does not poison the slot on a non-StandardError (Interrupt propagates, a retry can still succeed)" do
    raised = false
    expect do
      holder.fetch do
        raised = true
        raise Interrupt
      end
    end.to raise_error(Interrupt)

    expect(holder.fetch { :recovered }).to eq(:recovered)
    expect(raised).to be(true)
  end
end
