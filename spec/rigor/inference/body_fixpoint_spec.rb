# frozen_string_literal: true

require "spec_helper"

# Unit-level coverage for {Rigor::Inference::BodyFixpoint} (ADR-56 WD3) —
# the capped-fixpoint mechanism shared by the non-escaping block
# captured-local write-back (slice A) and the loop-body fixpoint (slice
# B). `evaluate_body` and `widen` are plain callables, so the contract
# pins directly against hand-built `evaluate_body` lambdas rather than
# going through the flow engine (that integration is exercised by the
# loop / block specs under `spec/integration/`).
RSpec.describe Rigor::Inference::BodyFixpoint do
  let(:widen) { Rigor::Type::Combinator.method(:widen_value_pinned) }

  def constant(value)
    Rigor::Type::Combinator.constant_of(value)
  end

  def nominal(name)
    Rigor::Type::Combinator.nominal_of(name)
  end

  before do
    Rigor::Inference::BudgetTrace.disable!
    Rigor::Inference::BudgetTrace.reset
  end

  after do
    Rigor::Inference::BudgetTrace.disable!
    Rigor::Inference::BudgetTrace.reset
  end

  describe ".converge" do
    it "returns an empty binding when there are no tracked names" do
      calls = 0
      result = described_class.converge(
        names: [], seed_bindings: {}, widen: widen, evaluate_body: lambda { |_bindings|
          calls += 1
          {}
        }
      )

      expect(result).to eq({})
      # The body is never evaluated when there is nothing to converge.
      expect(calls).to eq(0)
    end

    it "keeps every name at its seed binding when the body writes nothing (0-iteration soundness)" do
      seed = { a: constant(1), b: nominal("String") }

      result = described_class.converge(
        names: %i[a b], seed_bindings: seed, widen: widen, evaluate_body: ->(_bindings) { {} }
      )

      expect(result).to eq(seed)
    end

    it "breaks early once a single pass is already stable" do
      seed = { a: nominal("Integer") }
      calls = 0

      result = described_class.converge(
        names: [:a], seed_bindings: seed, widen: widen,
        evaluate_body: lambda { |_bindings|
          calls += 1
          { a: nominal("Integer") }
        }
      )

      expect(result).to eq(seed)
      # Joining the exit type back into an equal assumption is stable on
      # the very first pass, so the loop breaks instead of running to CAP.
      expect(calls).to eq(1)
    end

    it "joins the seed with a genuinely new exit type" do
      seed = { a: nominal("String") }
      calls = 0

      result = described_class.converge(
        names: [:a], seed_bindings: seed, widen: widen,
        evaluate_body: lambda { |_bindings|
          calls += 1
          calls == 1 ? { a: nominal("Integer") } : {}
        }
      )

      expect(result).to eq({ a: Rigor::Type::Combinator.union(nominal("String"), nominal("Integer")) })
    end

    it "converges within the cap when the join stabilizes after a couple of passes" do
      seed = { a: constant(0) }
      calls = 0

      result = described_class.converge(
        names: [:a], seed_bindings: seed, widen: widen,
        evaluate_body: lambda { |bindings|
          calls += 1
          if calls == 1
            { a: Rigor::Type::Combinator.union(bindings[:a], constant(1)) }
          else
            # Re-offers the same (now-joined) type; the next pass is stable.
            { a: bindings[:a] }
          end
        }
      )

      expect(result).to eq({ a: Rigor::Type::Combinator.union(constant(0), constant(1)) })
      # Stabilizes on pass 2, one short of the 3-pass cap.
      expect(calls).to eq(2)
      expect(calls).to be < described_class::CAP
    end

    it "widens a non-converging value-pinned accumulator to its nominal base on the final iteration" do
      seed = { a: constant(1) }
      calls = 0

      result = described_class.converge(
        names: [:a], seed_bindings: seed, widen: widen,
        evaluate_body: lambda { |_bindings|
          calls += 1
          # A fresh Constant every pass (`+= 1`-style accumulator):
          # never join-stable under plain `union`.
          { a: constant(calls + 1) }
        }
      )

      expect(calls).to eq(described_class::CAP)
      expect(result).to eq({ a: nominal("Integer") })
    end

    it "floors a structurally compounding local to Dynamic[top] and records a BudgetTrace hit" do
      Rigor::Inference::BudgetTrace.enable!
      seed = { a: constant(1) }
      calls = 0

      result = described_class.converge(
        names: [:a], seed_bindings: seed, widen: widen,
        evaluate_body: lambda { |bindings|
          calls += 1
          # `a = [a]` — grows structurally each pass, so even widening
          # both sides on the final iteration cannot make the join
          # collapse back to the widened assumption.
          { a: Rigor::Type::Combinator.tuple_of(bindings[:a]) }
        }
      )

      expect(calls).to eq(described_class::CAP)
      expect(result[:a]).to eq(Rigor::Type::Combinator.untyped)
      expect(Rigor::Inference::BudgetTrace.snapshot[Rigor::Inference::BudgetTrace::BLOCK_WRITEBACK_CAP]).to eq(1)
    end

    it "does not record a BudgetTrace hit when convergence succeeds" do
      Rigor::Inference::BudgetTrace.enable!
      seed = { a: nominal("Integer") }

      described_class.converge(
        names: [:a], seed_bindings: seed, widen: widen,
        evaluate_body: ->(_bindings) { { a: nominal("Integer") } }
      )

      expect(Rigor::Inference::BudgetTrace.snapshot[Rigor::Inference::BudgetTrace::BLOCK_WRITEBACK_CAP]).to eq(0)
    end

    it "leaves an unwritten name at its seed while another name in the same pass moves" do
      seed = { a: constant(1), b: nominal("String") }
      calls = 0

      result = described_class.converge(
        names: %i[a b], seed_bindings: seed, widen: widen,
        evaluate_body: lambda { |bindings|
          calls += 1
          if calls == 1
            # Only `a` is written this pass; `b` is absent from the
            # returned hash and must keep its current assumption.
            { a: Rigor::Type::Combinator.union(bindings[:a], constant(2)) }
          else
            {}
          end
        }
      )

      expect(result).to eq({ a: Rigor::Type::Combinator.union(constant(1), constant(2)), b: nominal("String") })
    end
  end
end
