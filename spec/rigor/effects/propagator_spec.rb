# frozen_string_literal: true

require "rigor/effects/propagator"

RSpec.describe Rigor::Effects::Propagator do
  def summary(*names, exhaustive: true, causes: [])
    bundles = names.empty? ? {} : { Rigor::Effects::Origin.catalogue("row") => Rigor::Effects::LabelSet.new(names) }
    Rigor::Effects::Summary.new(bundles: bundles, exhaustive: exhaustive, causes: causes)
  end

  def edge(receiver, selector, kind: :instance)
    Rigor::Effects::FileCollection::Edge.new(
      receiver_class: receiver, kind: kind, selector: selector, self_call: false
    )
  end

  # What a `super` records (#446): the enclosing unit's own class and selector, resolved above them.
  def super_edge(owner, selector, kind: :instance)
    Rigor::Effects::FileCollection::Edge.new(
      receiver_class: owner, kind: kind, selector: selector, self_call: true, super_call: true
    )
  end

  def collection(summaries:, edges: {}, superclasses: {}, includes: {})
    Rigor::Effects::FileCollection.new(
      summaries: summaries, edges: edges, superclasses: superclasses, includes: includes
    )
  end

  it "joins a callee's proven labels into its caller, transitively" do
    table = described_class.propagate(
      collection(
        summaries: { "A#outer" => summary, "A#middle" => summary, "A#inner" => summary("io.fs.read") },
        edges: { "A#outer" => [edge("A", "middle")], "A#middle" => [edge("A", "inner")] }
      )
    )

    expect(table["A#outer"].proven.to_a).to eq(["io.fs.read"])
    expect(table["A#outer"].direct.proven).to be_empty
  end

  # The lattice is finite and every step is monotone, so a cycle converges on its own — no recursion cap
  # is needed here, unlike the return-type walk's Kleene iteration.
  it "converges on mutual recursion" do
    table = described_class.propagate(
      collection(
        summaries: { "A#ping" => summary("exit"), "A#pong" => summary("io") },
        edges: { "A#ping" => [edge("A", "pong")], "A#pong" => [edge("A", "ping")] }
      )
    )

    expect(table["A#ping"].proven.to_a).to eq(%w[exit io])
    expect(table["A#pong"].proven.to_a).to eq(%w[exit io])
  end

  it "propagates the exhaustiveness bit and the causes behind it along edges" do
    table = described_class.propagate(
      collection(
        summaries: { "A#caller" => summary, "A#callee" => summary(exhaustive: false, causes: [["dynamic-send", nil]]) },
        edges: { "A#caller" => [edge("A", "callee")] }
      )
    )

    expect(table["A#caller"]).not_to be_exhaustive
    expect(table["A#caller"].causes).to eq([["dynamic-send", nil]])
    expect(table["A#caller"].direct).to be_exhaustive
  end

  it "resolves an edge through the superclass chain" do
    table = described_class.propagate(
      collection(
        summaries: { "Sub#run" => summary, "Base#emit" => summary("io.output.stdout") },
        edges: { "Sub#run" => [edge("Sub", "emit")] },
        superclasses: { "Sub" => ["Base"] }
      )
    )

    expect(table["Sub#run"].proven.to_a).to eq(["io.output.stdout"])
  end

  # Ruby has no `final`, so the summary of a call on a base class joins every project-known override —
  # the same closed-world posture the analyzer already takes for types (ADR-103 WD4).
  it "joins every project-known override of the call's target" do
    table = described_class.propagate(
      collection(
        summaries: { "A#run" => summary, "Base#emit" => summary, "Loud#emit" => summary("io.output.stdout") },
        edges: { "A#run" => [edge("Base", "emit")] },
        superclasses: { "Loud" => ["Base"] }
      )
    )

    expect(table["A#run"].proven.to_a).to eq(["io.output.stdout"])
    expect(table["A#run"].edges).to eq(%w[Base#emit Loud#emit])
  end

  # A short as-written superclass must not let two same-named classes in different namespaces share
  # overrides — that would put a label the code does not contain into the proven lane.
  it "resolves an as-written superclass to the namespace that defines it" do
    table = described_class.propagate(
      collection(
        summaries: { "T::D#run" => summary, "T::Base#emit" => summary, "T::Loud#emit" => summary("exit"),
                     "Other::Loud#emit" => summary("io.process") },
        edges: { "T::D#run" => [edge("T::Base", "emit")] },
        superclasses: { "T::Loud" => ["T::Base", "Base"], "Other::Loud" => ["Other::Base", "Base"] }
      )
    )

    expect(table["T::D#run"].proven.to_a).to eq(["exit"])
  end

  # #446 — a `super` edge carries the ENCLOSING unit's class and selector, and resolves above it.
  describe "a super edge" do
    it "resolves to the definition the ancestry above the enclosing class answers with" do
      table = described_class.propagate(
        collection(
          summaries: { "Sub#emit" => summary, "Base#emit" => summary("io.fs.read") },
          edges: { "Sub#emit" => [super_edge("Sub", "emit")] },
          superclasses: { "Sub" => ["Base"] }
        )
      )

      expect(table["Sub#emit"].proven.to_a).to eq(["io.fs.read"])
      expect(table["Sub#emit"]).to be_exhaustive
    end

    # `include M` puts `M#emit` between the class and its superclass, which is where `super` looks first.
    it "resolves through an included module before the superclass" do
      table = described_class.propagate(
        collection(
          summaries: { "Sub#emit" => summary, "M#emit" => summary("io.fs.write"), "Base#emit" => summary("exit") },
          edges: { "Sub#emit" => [super_edge("Sub", "emit")] },
          superclasses: { "Sub" => ["Base"] }, includes: { "Sub" => ["M"] }
        )
      )

      expect(table["Sub#emit"].proven.to_a).to eq(["io.fs.write"])
    end

    # The guard rail, and the one place a super edge must differ from an ordinary one: `super` in `Sub#emit`
    # dispatches into `Sub`'s ancestors, and `Deep` is never among them however the receiver was built. The
    # closed-world join that is right for `x.emit` would put a label here that no execution can produce.
    it "does not join a subclass override the way an ordinary call edge does" do
      table = described_class.propagate(
        collection(
          summaries: { "Sub#emit" => summary, "Base#emit" => summary("io.fs.read"),
                       "Deep#emit" => summary("io.process") },
          edges: { "Sub#emit" => [super_edge("Sub", "emit")] },
          superclasses: { "Sub" => ["Base"], "Deep" => ["Sub"] }
        )
      )

      expect(table["Sub#emit"].proven.to_a).to eq(["io.fs.read"])
      expect(table["Sub#emit"].edges).to eq(["Base#emit"])
    end

    it "never resolves to the enclosing definition itself" do
      table = described_class.propagate(
        collection(
          summaries: { "Solo#emit" => summary("io.fs.read") },
          edges: { "Solo#emit" => [super_edge("Solo", "emit")] }
        )
      )

      expect(table["Solo#emit"].edges).to be_empty
    end

    # Where an ordinary unresolved edge is dropped in silence, an unresolved `super` taints: the parent is
    # in a gem, in core, or in a module prepended at run time, and the row must not claim completeness.
    it "taints the caller when the project's ancestry answers nothing" do
      table = described_class.propagate(
        collection(
          summaries: { "Sub#emit" => summary }, edges: { "Sub#emit" => [super_edge("Sub", "emit")] },
          superclasses: { "Sub" => ["ActiveRecord::Base"] }
        )
      )

      expect(table["Sub#emit"]).not_to be_exhaustive
      expect(table["Sub#emit"].causes).to eq([%w[unresolved-super emit]])
    end

    # The taint is seeded before the fixpoint, so it travels to callers exactly as a collected one does.
    it "carries the taint to the callers of the delegating method" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Sub#emit" => summary },
          edges: { "A#run" => [edge("Sub", "emit")], "Sub#emit" => [super_edge("Sub", "emit")] }
        )
      )

      expect(table["A#run"]).not_to be_exhaustive
      expect(table["A#run"].causes).to eq([%w[unresolved-super emit]])
    end

    it "resolves the singleton side through the superclass chain" do
      table = described_class.propagate(
        collection(
          summaries: { "Sub.build" => summary, "Base.build" => summary("nondet.time") },
          edges: { "Sub.build" => [super_edge("Sub", "build", kind: :singleton)] },
          superclasses: { "Sub" => ["Base"] }
        )
      )

      expect(table["Sub.build"].proven.to_a).to eq(["nondet.time"])
    end
  end

  it "drops an edge that reaches no project definition rather than tainting" do
    table = described_class.propagate(
      collection(summaries: { "A#run" => summary }, edges: { "A#run" => [edge("String", "upcase")] })
    )

    expect(table["A#run"]).to be_exhaustive
    expect(table["A#run"].edges).to be_empty
  end

  # Fail-soft (ADR-103 WD13): propagation is a report surface, so a bug in it costs the report and never
  # the run that produced the summaries.
  it "answers an empty table rather than raising when propagation fails" do
    allow(described_class::Index).to receive(:new).and_raise("boom")

    expect(described_class.propagate(collection(summaries: { "A#run" => summary }))).to be_empty
  end
end
