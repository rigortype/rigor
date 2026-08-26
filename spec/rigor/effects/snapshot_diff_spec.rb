# frozen_string_literal: true

require "rigor/effects/snapshot_diff"

# ADR-103 #381 — the event vocabulary of a snapshot comparison, and the two judgment knobs applied on
# top of it: the gate and the tolerated set. The comparison itself is exact; only the judgment has policy.
RSpec.describe Rigor::Effects::SnapshotDiff do
  def header_row(**overrides)
    { "schema" => 1, "rigor" => "0.3.3", "vocabulary" => 1, "config_digest" => "abc" }.merge(overrides)
  end

  def entry(key, effects: [], declared: [], exhaustive: true, unresolved: [])
    Rigor::Effects::Snapshot::Entry.new(key: key, effects: effects, declared: declared,
                                        exhaustive: exhaustive, unresolved: unresolved)
  end

  def snapshot(methods: {}, reach: {}, header: header_row)
    Rigor::Effects::Snapshot.new(header: header, methods: methods, reach: reach)
  end

  def compare(before, after, **)
    described_class.compare(recorded: before, current: after, **)
  end

  def categories(diff)
    diff.events.map(&:category)
  end

  it "is fresh when the two sides agree" do
    one = snapshot(methods: { "A#m" => entry("A#m", effects: ["io"]) })

    expect(compare(one, one)).to be_fresh
    expect(compare(one, one)).not_to be_drift
  end

  describe "label events" do
    it "reports an added and a removed label per method" do
      diff = compare(snapshot(methods: { "A#m" => entry("A#m", effects: %w[io nondet.time]) }),
                     snapshot(methods: { "A#m" => entry("A#m", effects: %w[io io.fs.read]) }))

      expect(diff.events.map { |event| [event.category, event.label] }).to contain_exactly(
        [described_class::LABEL_ADDED, "io.fs.read"], [described_class::LABEL_REMOVED, "nondet.time"]
      )
    end

    # "Possibly more" cannot prove an absence, so a removal read off a non-exhaustive current side is
    # hedged rather than asserted.
    it "hedges a removal when the current summary is not exhaustive" do
      diff = compare(snapshot(methods: { "A#m" => entry("A#m", effects: ["io"]) }),
                     snapshot(methods: { "A#m" => entry("A#m", exhaustive: false) }))

      removal = diff.events.find { |event| event.category == described_class::LABEL_REMOVED }

      expect(removal).to be_hedged
    end

    it "reports the declared lane separately" do
      diff = compare(snapshot(methods: { "A#m" => entry("A#m", declared: ["io"]) }),
                     snapshot(methods: { "A#m" => entry("A#m", declared: ["nondet"]) }))

      expect(categories(diff)).to contain_exactly(described_class::DECLARED_ADDED,
                                                  described_class::DECLARED_REMOVED)
    end

    # Materialisation is ONE event, never a declared removal plus a proven addition: the label did not
    # come or go, it stopped being a claim and became a fact.
    it "reports a declared label that became proven as one materialisation" do
      diff = compare(snapshot(methods: { "A#m" => entry("A#m", declared: ["io.net.http"]) }),
                     snapshot(methods: { "A#m" => entry("A#m", effects: ["io.net.http"]) }))

      expect(categories(diff)).to eq([described_class::MATERIALISED])
    end
  end

  # Someone introduced a call the analyzer cannot follow, or removed one. Its own category, because it is
  # a change in what is KNOWN rather than in what happens.
  describe "exhaustiveness transitions" do
    it "reports each direction as its own event" do
      exhaustive = snapshot(methods: { "A#m" => entry("A#m", effects: ["io"]) })
      tainted = snapshot(methods: { "A#m" => entry("A#m", effects: ["io"], exhaustive: false) })

      expect(categories(compare(exhaustive, tainted))).to eq([described_class::EXHAUSTIVE_LOST])
      expect(categories(compare(tainted, exhaustive))).to eq([described_class::EXHAUSTIVE_GAINED])
    end
  end

  describe "symbol events" do
    it "reports a new symbol with a non-empty summary as drift and counts it in the footer" do
      diff = compare(snapshot, snapshot(methods: { "A#m" => entry("A#m", effects: ["io"]) }))

      expect(categories(diff)).to eq([described_class::SYMBOL_ADDED])
      expect(diff.footer).to eq(added_symbols: 1, removed_symbols: 0, suppressed: 0)
    end

    # A rename is a removal plus an addition and is never reported as a lost effect; the footer is where
    # a reviewer sees the two counts balance.
    it "counts a rename as one of each" do
      diff = compare(snapshot(methods: { "A#old" => entry("A#old", effects: ["io"]) }),
                     snapshot(methods: { "A#new" => entry("A#new", effects: ["io"]) }))

      expect(diff.footer).to eq(added_symbols: 1, removed_symbols: 1, suppressed: 0)
      expect(categories(diff)).to contain_exactly(described_class::SYMBOL_ADDED,
                                                  described_class::SYMBOL_REMOVED)
    end

    # A row carrying nothing appears only under `--full`; its coming and going is not news, though the
    # footer still counts it so a rename still balances.
    it "stays quiet about a symbol with nothing to say" do
      diff = compare(snapshot, snapshot(methods: { "A#m" => entry("A#m") }))

      expect(diff.events).to be_empty
      expect(diff.footer).to eq(added_symbols: 1, removed_symbols: 0, suppressed: 0)
    end
  end

  # The record was written under different rules — a different Rigor, vocabulary or `effects:` block — so
  # the two sides are not comparable and there is nothing to ratchet against.
  describe "header mismatch" do
    it "reports a regeneration event and fails under both gates" do
      diff = compare(snapshot, snapshot(header: header_row("vocabulary" => 2)))

      expect(categories(diff)).to eq([described_class::REGENERATION])
      expect(diff).to be_drift
      expect(compare(snapshot, snapshot(header: header_row("vocabulary" => 2)), gate: :additions)).to be_drift
    end
  end

  it "treats a missing snapshot as routed drift rather than an error" do
    diff = compare(nil, snapshot)

    expect(categories(diff)).to eq([described_class::MISSING_SNAPSHOT])
    expect(diff.events.first.detail).to include("rigor effects update")
    expect(diff).to be_drift
  end

  describe "the gate" do
    let(:before_side) { snapshot(methods: { "A#m" => entry("A#m", effects: %w[io nondet.time]) }) }
    let(:after_side) { snapshot(methods: { "A#m" => entry("A#m", effects: ["io"]) }) }

    # A removal is news too — a job that stopped enqueueing is a bug, not an improvement.
    it "fails symmetrically by default" do
      expect(compare(before_side, after_side)).to be_drift
    end

    it "lets a removal through under the additions ratchet" do
      expect(compare(before_side, after_side, gate: :additions)).not_to be_drift
    end

    it "still fails the ratchet on growth" do
      expect(compare(after_side, before_side, gate: :additions)).to be_drift
    end
  end

  describe "tolerated at judgment time" do
    let(:before_side) { snapshot(methods: { "A#m" => entry("A#m") }) }
    let(:after_side) { snapshot(methods: { "A#m" => entry("A#m", effects: ["nondet.time"]) }) }

    it "reports a tolerated change without failing the gate" do
      diff = compare(before_side, after_side, tolerated: ["nondet"])

      expect(diff.tolerated_events.map(&:label)).to eq(["nondet.time"])
      expect(diff.events_for("methods")).to be_empty
      expect(diff).not_to be_drift
      expect(diff).not_to be_fresh
    end

    it "fails on it under strict_tolerated" do
      expect(compare(before_side, after_side, tolerated: ["nondet"], strict_tolerated: true)).to be_drift
    end

    it "tolerates a symbol only when every label it carries is admitted" do
      added = snapshot(methods: { "A#new" => entry("A#new", effects: %w[io.fs.read nondet.time]) })

      expect(compare(snapshot, added, tolerated: ["nondet"])).to be_drift
      expect(compare(snapshot, added, tolerated: %w[nondet io.fs])).not_to be_drift
    end

    it "never tolerates an exhaustiveness transition, which carries no label to discharge" do
      diff = compare(snapshot(methods: { "A#m" => entry("A#m", effects: ["nondet.time"]) }),
                     snapshot(methods: { "A#m" => entry("A#m", effects: ["nondet.time"], exhaustive: false) }),
                     tolerated: ["nondet"])

      expect(diff).to be_drift
    end
  end

  # ADR-103 WD14 / #385 — discharge is per ORIGIN, and the current side of a comparison still has its
  # origins even though the file does not. When the caller hands them over, an ADDED label is judged
  # exactly: tolerated iff every origin introducing it is discharged.
  describe "per-origin judgment of additions" do
    let(:before_side) { snapshot(methods: { "A#m" => entry("A#m") }) }
    let(:after_side) { snapshot(methods: { "A#m" => entry("A#m", effects: %w[io telemetry]) }) }

    # `io` arrived with the tolerated `telemetry`, in one bundle, so nothing survives and the whole
    # addition is discharged — where the label reading would have failed the gate on the bare `io`.
    it "discharges a label whose every origin is discharged" do
      diff = compare(before_side, after_side, tolerated: ["telemetry"],
                                              undischarged: { "methods" => { "A#m" => [] } })

      expect(diff.tolerated_events.map(&:label)).to eq(%w[io telemetry])
      expect(diff).not_to be_drift
    end

    it "keeps a label that also arrived through an undischarged origin" do
      diff = compare(before_side, after_side, tolerated: ["telemetry"],
                                              undischarged: { "methods" => { "A#m" => ["io"] } })

      expect(diff.events_for("methods").map(&:label)).to eq(["io"])
      expect(diff).to be_drift
    end

    # A removal has no current-side origin to consult — the thing that produced it is gone — so it is
    # judged by label, exactly as before.
    it "judges a removal by label even with an index present" do
      diff = compare(snapshot(methods: { "A#m" => entry("A#m", effects: ["nondet.time"]) }),
                     snapshot(methods: { "A#m" => entry("A#m") }),
                     tolerated: ["nondet"], undischarged: { "methods" => { "A#m" => [] } })

      expect(diff.tolerated_events.map(&:category)).to eq([described_class::LABEL_REMOVED])
    end

    it "falls back to the label reading for a symbol the index does not carry" do
      diff = compare(before_side, after_side, tolerated: %w[io telemetry], undischarged: { "methods" => {} })

      expect(diff.tolerated_events.map(&:label)).to eq(%w[io telemetry])
    end
  end

  it "compares the reach table alongside the methods table" do
    diff = compare(snapshot(reach: { "A#action" => entry("A#action") }),
                   snapshot(reach: { "A#action" => entry("A#action", effects: ["io"]) }))

    expect(diff.events_for("reach").map(&:label)).to eq(["io"])
    expect(diff.events_for("methods")).to be_empty
  end
end
