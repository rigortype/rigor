# frozen_string_literal: true

require "rigor"
require "rigor/analysis/runner"

# ADR-103 #446 — `super` as a dispatch, end to end over the fixture app in
# `spec/integration/fixtures/effects/super_edge`. Before this, a `super` contributed nothing AND left the
# row exhaustive, so a method whose whole body delegates upward read as provably effect-free and passed
# any envelope. The resolution rules over a synthetic table are `spec/rigor/effects/propagator_spec.rb`.
RSpec.describe "a super call in an effect summary" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/super_edge", __dir__)
  end

  def configuration(effects: {}, workers: 0)
    data = { "paths" => ["lib"], "parallel" => { "workers" => workers } }
    data["effects"] = effects
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  def analyze(configuration)
    Dir.chdir(fixture) do
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      diagnostics = guarded_run(runner, ["lib"]).diagnostics
      [runner.effect_table, diagnostics]
    end
  end

  let(:table) { analyze(configuration).first }

  # The issue's own reproduction. `[]` and exhaustive is the one answer that is not allowed.
  it "gives a body that is nothing but super the parent's proven labels" do
    entry = table["SuperEdge::Bare#emit"]

    expect(entry.proven.to_a).to eq(["io.fs.read"])
    expect(entry).to be_exhaustive
    expect(entry.edges).to eq(["SuperEdge::BaseWriter#emit"])
  end

  it "records the edge for super(), for super(args), and for a super inside a block or a rescue" do
    expect(table["SuperEdge::Parens#emit"].proven.to_a).to eq(["io.fs.read"])
    expect(table["SuperEdge::Args#emit"].proven.to_a).to eq(["io.fs.write"])
    expect(table["SuperEdge::InBlock#emit"].proven.to_a).to eq(["io.fs.read"])
    expect(table["SuperEdge::InRescue#emit"].proven.to_a).to eq(["io.fs.read"])
  end

  it "resolves the singleton side of super through the superclass chain" do
    expect(table["SuperEdge::Singleton.build"].proven.to_a).to eq(["io.output.stdout"])
  end

  # `include` is a call on `self`, so where `self` is the singleton class it does what `extend` does, and an
  # instance-side `super` skips the module. The collection used to record it as an instance-side include, and
  # the `super` in each of the first three resolved to `Auditing#emit`, putting its write on a method that
  # reads. `instance_eval` moves only the definee, so its `include` is still the class's own.
  describe "with an include whose receiver may be the singleton class" do
    # Ruby's own answer: the fixture is evaluated into an anonymous namespace, as `definition_side_spec.rb`
    # does, so the file's claims are checked here and not only in its comment.
    let(:evaluated) do
      namespace = Module.new
      %w[base.rb singleton_include.rb].each do |file|
        path = File.join(fixture, "lib", file)
        namespace.module_eval(File.read(path), path)
      end
      namespace.const_get(:SuperEdge)
    end

    # class name => [the class `super` in #emit reaches, the labels it reads through that edge]
    {
      "EigenInclude" => ["BaseWriter", "io.fs.read"],
      "SingletonClassEvalInclude" => ["BaseWriter", "io.fs.read"],
      "EigenPrepend" => ["BaseWriter", "io.fs.read"],
      "InstanceEvalInclude" => ["Auditing", "io.fs.write"]
    }.each do |name, (owner, label)|
      it "resolves super in #{name}#emit to #{owner}#emit, as Ruby does" do
        klass = evaluated.const_get(name)
        expect(klass.instance_method(:emit).super_method.owner).to equal(evaluated.const_get(owner))

        entry = table["SuperEdge::#{name}#emit"]
        expect(entry.edges).to eq(["SuperEdge::#{owner}#emit"])
        expect(entry.proven.to_a).to eq([label])
        expect(entry).to be_exhaustive
      end
    end
  end

  # The honest answer where the ancestry answers nothing — a gem's base class, Ruby's own core, a module
  # prepended at run time. Empty, and hedged; never empty and exhaustive.
  it "taints a super the project's ancestry cannot resolve rather than reading it as effect-free" do
    entry = table["SuperEdge::Unresolvable#to_s"]

    expect(entry.proven).to be_empty
    expect(entry).not_to be_exhaustive
    expect(entry.causes).to eq([%w[unresolved-super to_s]])
  end

  # The parent lives in another file, so this is also the marshal round trip: a worker's collection carries
  # the `super_call` bit back, and the fixpoint over the merged tables answers the same as a sequential run.
  it "answers identically when the collections come back from a pool worker" do
    pooled = analyze(configuration(workers: 2)).first

    expect(pooled["SuperEdge::Bare#emit"].proven.to_a).to eq(["io.fs.read"])
    expect(pooled["SuperEdge::Unresolvable#to_s"].causes).to eq([%w[unresolved-super to_s]])
  end

  it "carries both answers to a caller" do
    expect(table["SuperEdge::Client#run"].proven.to_a).to eq(["io.fs.read"])
    expect(table["SuperEdge::Client#describe"]).not_to be_exhaustive
    expect(table["SuperEdge::Client#describe"].causes).to eq([%w[unresolved-super to_s]])
  end

  # The acceptance criterion that makes this a soundness fix rather than a precision one: the declared
  # lane is the only half of the effect system that can fail a build, and an override that delegates
  # upward must be judged on what the parent does.
  describe "under an `effect: []` envelope over the same directory" do
    let(:findings) do
      _, diagnostics = analyze(
        configuration(effects: { "envelopes" => [{ "match" => "lib/**/*.rb", "effect" => [] }] })
      )
      diagnostics.select { |d| d.rule == "effect.envelope-exceeded" }
                 .map { |d| d.message[/Method (\S+) performs/, 1] }.sort
    end

    it "flags the delegating override as well as the parent" do
      expect(findings).to include("SuperEdge::BaseWriter#emit", "SuperEdge::Bare#emit")
    end

    # A taint contributes no finding of its own: an unresolvable `super` says "and possibly more", which
    # withholds the pass rather than manufacturing a failure.
    it "does not fire on the method whose super it could not resolve" do
      expect(findings).not_to include("SuperEdge::Unresolvable#to_s")
    end
  end
end
