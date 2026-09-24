# frozen_string_literal: true

require "rigor"
require "rigor/analysis/runner"

# ADR-103 #1039 — `Const.new` as a dispatch to `Const#initialize`, end to end over the fixture app in
# `spec/integration/fixtures/effects/constructor_edge`. Before this, the collector recorded the call as
# `(Const, :singleton, "new")`, nothing in the project defined `Const.new`, and every constructor body
# stayed out of its caller's closure while marking the caller unclaimed (#391). The resolution rules over
# a synthetic table are `spec/rigor/effects/propagator_spec.rb`.
RSpec.describe "a Const.new call in an effect summary" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/constructor_edge", __dir__)
  end

  def configuration(workers: 0)
    data = { "paths" => ["lib"], "parallel" => { "workers" => workers }, "effects" => {} }
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  def analyze(configuration)
    Dir.chdir(fixture) do
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      guarded_run(runner, ["lib"])
      runner.effect_table
    end
  end

  let(:table) { analyze(configuration) }

  # The issue's own reproduction: the constructor writes an ivar and calls a catalogued effectful method,
  # and both have to reach the caller.
  it "gives a caller the constructor's labels" do
    entry = table["ConstructorEdge::Client#record"]

    expect(entry.proven.to_a).to include("io.fs.write")
    expect(entry.edges).to eq(["ConstructorEdge::Recorder#initialize"])
    expect(entry).not_to be_unclaimed
  end

  # `new` with no receiver inside a singleton body is the same edge as `Recorder.new`.
  it "resolves a receiver-less new inside a singleton body" do
    expect(table["ConstructorEdge::Recorder.build"].proven.to_a).to include("io.fs.write")
    expect(table["ConstructorEdge::Client#via_singleton"].proven.to_a).to include("io.fs.write")
  end

  # The ancestor walk is `resolve_owner`'s, so an `#initialize` inherited from another file resolves.
  it "resolves an inherited #initialize" do
    entry = table["ConstructorEdge::Client#inherit"]

    expect(entry.proven.to_a).to include("io.fs.write")
    expect(entry.edges).to eq(["ConstructorEdge::BaseWriter#initialize"])
    expect(entry).not_to be_unclaimed
  end

  # The design choice: a class whose project ancestry defines no `#initialize` and closes inside the
  # project is constructed by `BasicObject#initialize`, whose footprint is ∅. The edge resolves to nothing
  # AND the caller is not unclaimed — no summary row is invented for it.
  it "leaves a caller of a constructor-less class neither labelled nor unclaimed" do
    entry = table["ConstructorEdge::Client#bare"]

    expect(entry.proven).to be_empty
    expect(entry.edges).to be_empty
    expect(entry).not_to be_unclaimed
    expect(entry).to be_exhaustive
  end

  # `include` inside `class << self` mixes the module into the singleton class, so `Setup#initialize` is a
  # class method `new` never calls. Recorded as an instance-side include, it was the constructor the rule
  # found, and its write reached a caller whose `new` runs `BasicObject#initialize`.
  it "takes no constructor from a module included into the singleton class" do
    entry = table["ConstructorEdge::EigenClient#build"]

    expect(entry.proven).to be_empty
    expect(entry.edges).to be_empty
    expect(entry).not_to be_unclaimed
    expect(entry).to be_exhaustive
  end

  # A project `def self.new` is the definition the call actually reaches, and it must win over the
  # `#initialize` beside it.
  it "prefers a project def self.new over #initialize" do
    entry = table["ConstructorEdge::Client#intercept"]

    expect(entry.proven.to_a).to eq(["io.output.stdout"])
    expect(entry.edges).to eq(["ConstructorEdge::Overridden.new"])
  end

  # `Class.new` builds an anonymous class. It is not a constructor call on a project class, and must not
  # pick up any project `#initialize` — including the one on a class the project might name `Class`.
  it "leaves Class.new alone" do
    entry = table["ConstructorEdge::Client#anonymous"]

    expect(entry.proven).to be_empty
    expect(entry.edges).to be_empty
  end

  # The edge is keyed on the receiver's TYPE, so `self.class.new` inside `Spread` carries the identical
  # tuple as a literal `Spread.new` — and it really can construct a subclass. Dropping the closed-world
  # join for every shape would read `Spread#clone_like` as effect-free while `SpreadSub.new.clone_like`
  # writes a file.
  it "joins subclass constructors for a receiver that is not a written constant" do
    expect(table["ConstructorEdge::Spread#clone_like"].proven.to_a).to include("io.fs.write")
    expect(table["ConstructorEdge::Spread#via_local"].proven.to_a).to include("io.fs.write")
    expect(table["ConstructorEdge::Spread.build"].proven.to_a).to include("io.fs.write")
  end

  # ... and the other half of the same rule: a written constant names the class it constructs, so the join
  # must not put a subclass's label on it.
  it "does not join a subclass constructor onto a written constant receiver" do
    entry = table["ConstructorEdge::Spreader#literal"]

    expect(entry.proven).to be_empty
    expect(entry.edges).to be_empty
    expect(entry).not_to be_unclaimed
  end

  # A superclass expression the scanner cannot read as a constant path is not "no superclass at all": the
  # constructor is built at load time, which is the opposite of an absent one.
  it "declines on a class whose superclass is an expression" do
    entry = table["ConstructorEdge::Spreader#generated"]

    expect(entry.edges).to be_empty
    expect(entry).to be_unclaimed
  end

  # The scanner models no aliases, so an aliased `initialize` must not read as an absent one.
  it "declines on a class that aliases initialize" do
    entry = table["ConstructorEdge::Spreader#aliased"]

    expect(entry.edges).to be_empty
    expect(entry).to be_unclaimed
  end

  # The `class K < Struct.new(:a)` case in its other spelling: the class is built by a load-time call and
  # only its REOPENING is a `class` body, so the scan would otherwise see a project-known class with no
  # ancestry at all and read the silence as "no constructor anywhere".
  it "declines on a reopened class that a load-time call built" do
    expect(table["ConstructorEdge::Reopener#anon"].edges).to be_empty
    expect(table["ConstructorEdge::Reopener#anon"]).to be_unclaimed
    expect(table["ConstructorEdge::Reopener#point"]).to be_unclaimed
  end

  # The alias sentinel has to be looked for DOWNWARD too: the closed-world join is the only reason this
  # edge may construct `AliasedChild` at all, and `AliasedChild#initialize` is a key that does not exist.
  it "declines when a subclass reachable through the join has an unreadable constructor" do
    entry = table["ConstructorEdge::Widening#clone_like"]

    expect(entry.proven).to be_empty
    expect(entry).to be_unclaimed
  end

  # The sentinel is sticky. `Sticky` is built by `Class.new(BaseWriter) { def initialize … }` in `base.rb`
  # and reopened as `class Sticky < BaseWriter` in `constructors.rb`; the block's constructor is filed under
  # the enclosing namespace and cannot be attributed to the class, so the spelled superclass is less than
  # the sentinel says, not more.
  it "keeps the sentinel over a later reopening that spells a superclass" do
    entry = table["ConstructorEdge::Reopener#sticky"]

    expect(entry.proven).to be_empty
    expect(entry.edges).to be_empty
    expect(entry).to be_unclaimed
  end

  # `Class.new(Base)` keeps `Base` beside the sentinel, which is what files the built class as a subclass —
  # so the closed-world join sees the unreadable constructor below `Widened` and declines.
  it "declines a self.class.new whose load-time-built subclass is unreadable" do
    entry = table["ConstructorEdge::Widened#dup2"]

    expect(entry.proven).to be_empty
    expect(entry).to be_unclaimed
  end

  # The constructor lives in another file for the inherited case, so this is also the marshal round trip.
  it "answers identically when the collections come back from a pool worker" do
    pooled = analyze(configuration(workers: 2))

    expect(pooled["ConstructorEdge::Client#record"].proven.to_a).to include("io.fs.write")
    expect(pooled["ConstructorEdge::Client#inherit"].proven.to_a).to include("io.fs.write")
    expect(pooled["ConstructorEdge::Client#bare"]).not_to be_unclaimed
    expect(pooled["ConstructorEdge::Reopener#sticky"]).to be_unclaimed
  end
end
