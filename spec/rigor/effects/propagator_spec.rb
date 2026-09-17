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

  # #1039 — `new` is the one selector whose dispatch target is spelled under a different key. The end-to-end
  # shapes are `spec/rigor/effects/constructor_edge_spec.rb`.
  describe "a singleton `new` edge" do
    # A literal `Const.new`. The type-keyed tuple is the same one `self.class.new` records, which is what
    # `constant_receiver` exists to separate.
    def new_edge(receiver, constant: true)
      Rigor::Effects::FileCollection::Edge.new(
        receiver_class: receiver, kind: :singleton, selector: "new", self_call: false, unclaimed: true,
        constant_receiver: constant
      )
    end

    def opaque
      Rigor::Effects::FileCollection::OPAQUE_ANCESTOR
    end

    it "resolves to the receiver's own #initialize" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Const#initialize" => summary("io.fs.write") },
          edges: { "A#run" => [new_edge("Const")] }
        )
      )

      expect(table["A#run"].proven.to_a).to eq(["io.fs.write"])
      expect(table["A#run"].edges).to eq(["Const#initialize"])
      expect(table["A#run"]).not_to be_unclaimed
    end

    it "resolves through the superclass chain to an inherited #initialize" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Base#initialize" => summary("io.fs.write") },
          edges: { "A#run" => [new_edge("Sub")] }, superclasses: { "Sub" => ["Base"] }
        )
      )

      expect(table["A#run"].edges).to eq(["Base#initialize"])
    end

    # The design choice: an ancestry that closes inside the project with no `#initialize` anywhere is
    # constructed by `BasicObject#initialize`, whose footprint is ∅. Resolved to nothing, and claimed —
    # without a summary row being invented for a definition the project does not contain.
    it "resolves to nothing and claims the caller when the project ancestry defines no #initialize" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Bare#label" => summary },
          edges: { "A#run" => [new_edge("Bare")] }
        )
      )

      expect(table["A#run"].edges).to be_empty
      expect(table["A#run"]).not_to be_unclaimed
    end

    # ... which the walk may only say when it never left the project. A class whose superclass is a gem's
    # inherits that gem's constructor, and nobody described it.
    it "leaves the caller unclaimed when the ancestry leaves the project" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Sub#label" => summary },
          edges: { "A#run" => [new_edge("Sub")] }, superclasses: { "Sub" => ["ActiveRecord::Base"] }
        )
      )

      expect(table["A#run"].edges).to be_empty
      expect(table["A#run"]).to be_unclaimed
    end

    # An `include` is the same question, and the collection's flat candidate list cannot answer it: a
    # module is free to define `initialize`, and the table cannot say whether the module is the project's.
    it "leaves the caller unclaimed when the class includes anything" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Bare#label" => summary },
          edges: { "A#run" => [new_edge("Bare")] }, includes: { "Bare" => ["Comparable"] }
        )
      )

      expect(table["A#run"]).to be_unclaimed
    end

    it "prefers a project `def self.new` over #initialize, including an inherited one" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Base.new" => summary("exit"), "Sub#initialize" => summary("io") },
          edges: { "A#run" => [new_edge("Sub")] }, superclasses: { "Sub" => ["Base"] }
        )
      )

      expect(table["A#run"].edges).to eq(["Base.new"])
      expect(table["A#run"].proven.to_a).to eq(["exit"])
    end

    # `Class.new` builds an anonymous class. Even a project that reopens `Class` must not turn it into a
    # call on that reopening.
    it "never resolves Class.new, Module.new, Struct.new or Data.new to a project #initialize" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Class#initialize" => summary("io"), "Struct#initialize" => summary("io") },
          edges: { "A#run" => [new_edge("Class"), new_edge("Struct")] }
        )
      )

      expect(table["A#run"].edges).to be_empty
      expect(table["A#run"]).to be_unclaimed
    end

    # The `self.class.new` / `klass.new` / receiver-less-`new`-in-a-singleton-body shapes. They carry the
    # identical tuple as a written constant and really do construct a subclass, so the closed-world join
    # is theirs.
    it "joins subclass constructors when the receiver is not a written constant" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Base#label" => summary, "Sub#initialize" => summary("io.fs.write"),
                       "Other.new" => summary("exit") },
          edges: { "A#run" => [new_edge("Base", constant: false)] },
          superclasses: { "Sub" => ["Base"], "Other" => ["Base"] }
        )
      )

      expect(table["A#run"].proven.to_a).to eq(["exit", "io.fs.write"])
      expect(table["A#run"].edges).to eq(["Other.new", "Sub#initialize"])
    end

    # The must-not-add-label arm of the same table: a written constant names the class it constructs.
    it "keeps a written constant receiver clear of a subclass constructor" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Base#label" => summary, "Sub#initialize" => summary("io.fs.write") },
          edges: { "A#run" => [new_edge("Base")] }, superclasses: { "Sub" => ["Base"] }
        )
      )

      expect(table["A#run"].proven).to be_empty
      expect(table["A#run"].edges).to be_empty
      expect(table["A#run"]).not_to be_unclaimed
    end

    # `class K < Struct.new(:a)` records the opaque sentinel rather than nothing, so "no `<` at all" and
    # "a superclass the scan could not read" stop being the same table entry.
    it "declines when a superclass expression was not readable" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "K#initialize" => summary("io.fs.write") },
          edges: { "A#run" => [new_edge("K")] }, superclasses: { "K" => [opaque] }
        )
      )

      expect(table["A#run"].proven).to be_empty
      expect(table["A#run"].edges).to be_empty
      expect(table["A#run"]).to be_unclaimed
    end

    # The sentinel is looked for DOWNWARD as well, and only where the join applies: the join is the whole
    # reason a non-constant receiver may construct a subclass, and an unreadable subclass constructor is a
    # key {Index#subclass_constructors} cannot find.
    it "declines when a subclass reachable through the join is opaque" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Base#label" => summary, "Sub#setup" => summary("io.fs.write") },
          edges: { "A#run" => [new_edge("Base", constant: false)] },
          superclasses: { "Sub" => ["Base"] }, includes: { "Sub" => [opaque] }
        )
      )

      expect(table["A#run"].proven).to be_empty
      expect(table["A#run"]).to be_unclaimed
    end

    # ... and a written constant, which cannot reach that subclass, is unaffected by it.
    it "keeps resolving a written constant although a subclass is opaque" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "Base#initialize" => summary("io.fs.read"), "Sub#setup" => summary },
          edges: { "A#run" => [new_edge("Base")] },
          superclasses: { "Sub" => ["Base"] }, includes: { "Sub" => [opaque] }
        )
      )

      expect(table["A#run"].proven.to_a).to eq(["io.fs.read"])
      expect(table["A#run"]).not_to be_unclaimed
    end

    # The sentinel declines even where the ancestry DOES answer: an aliased `initialize` is not the
    # `#initialize` the walk would find.
    it "declines when the ancestry is opaque although an #initialize resolves" do
      table = described_class.propagate(
        collection(
          summaries: { "A#run" => summary, "K#initialize" => summary("io.fs.write") },
          edges: { "A#run" => [new_edge("K")] }, includes: { "K" => [opaque] }
        )
      )

      expect(table["A#run"].proven).to be_empty
      expect(table["A#run"]).to be_unclaimed
    end

    # A class the project never defines is a gem's, and its constructor is as undescribed as before.
    it "leaves a receiver the project does not define unclaimed" do
      table = described_class.propagate(
        collection(summaries: { "A#run" => summary }, edges: { "A#run" => [new_edge("Net::HTTP")] })
      )

      expect(table["A#run"].edges).to be_empty
      expect(table["A#run"]).to be_unclaimed
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
