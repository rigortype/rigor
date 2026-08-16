# frozen_string_literal: true

require "rigor/effects/summary"

RSpec.describe Rigor::Effects::Summary do
  def labels(*names)
    Rigor::Effects::LabelSet.new(names)
  end

  def origin(name)
    Rigor::Effects::Origin.construct(name)
  end

  it "projects the proven lane as the join of every bundle" do
    summary = described_class.new(
      bundles: { origin("a") => labels("io.fs.read"), origin("b") => labels("nondet.time") }
    )

    expect(summary.proven.to_a).to eq(%w[io.fs.read nondet.time])
  end

  it "leaves the declared lane empty — the envelope reader that fills it is a later slice" do
    expect(described_class.new(bundles: { origin("a") => labels("io") }).declared).to be_empty
  end

  # Reopenings of one method, and the several files that contribute to it, fold through `join`. The
  # merge has to be associative and commutative in every lane or a pooled run and a sequential run would
  # disagree on the same project.
  it "joins associatively in every lane" do
    left = described_class.new(bundles: { origin("a") => labels("io") }, exhaustive: false,
                               causes: [["dynamic-send", nil]])
    middle = described_class.new(bundles: { origin("a") => labels("exit") })
    right = described_class.new(bundles: { origin("b") => labels("nondet.time") })

    expect(left.join(middle).join(right)).to eq(left.join(middle.join(right)))
    expect(left.join(right)).to eq(right.join(left))
  end

  it "ANDs the exhaustiveness bit and unions causes on join" do
    tainted = described_class.tainted("dynamic-receiver", "external_gem_without_rbs")
    clean = described_class.new(bundles: { origin("a") => labels("io") })

    joined = clean.join(tainted)

    expect(joined).not_to be_exhaustive
    expect(joined.causes).to eq([%w[dynamic-receiver external_gem_without_rbs]])
  end

  # The taint-cause enum is closed (`docs/type-specification/effect-labels.md`). A producer that invents
  # a spelling is a bug in the producer — but the collector is fail-soft, so the value drops the cause
  # rather than raising and taking a run down.
  it "drops a cause outside the closed enum instead of raising" do
    summary = described_class.new(exhaustive: false, causes: [["invented-cause", nil], ["budget", nil]])

    expect(summary.causes).to eq([["budget", nil]])
  end

  it "normalises bundles so equal facts in different orders are ==" do
    one = described_class.new(bundles: { origin("a") => labels("io"), origin("b") => labels("exit") })
    other = described_class.new(bundles: { origin("b") => labels("exit"), origin("a") => labels("io") })

    expect(one).to eq(other)
    expect(one.hash).to eq(other.hash)
  end

  # The report omits a method whose whole footprint is frame-local mutation: `mutate.local` is tolerated
  # by every envelope, `%a{pure}` included, so such a method reads as pure to a reviewer.
  it "treats an exhaustive mutate.local-only summary as trivial" do
    local = described_class.new(bundles: { origin("receiver-mutation") => labels("mutate.local") })
    shared = described_class.new(bundles: { origin("receiver-mutation") => labels("mutate.self") })

    expect(local).to be_trivial
    expect(shared).not_to be_trivial
    expect(described_class.tainted("budget")).not_to be_trivial
  end

  # The fork pool marshals a file's summaries back to the parent with its diagnostics.
  it "round-trips through Marshal" do
    summary = described_class.new(bundles: { origin("a") => labels("io.fs.read") },
                                  exhaustive: false, causes: [%w[budget cap]])

    expect(Marshal.load(Marshal.dump(summary))).to eq(summary)
  end
end
