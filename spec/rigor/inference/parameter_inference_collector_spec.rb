# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/inference/parameter_inference_collector"
require "rigor/environment"

# ADR-67 WD3 — single-level call-site parameter inference. A parameter's inferred type is the union of resolved
# call-site argument types; an argument that is itself untyped (the fixpoint case) poisons the parameter.
RSpec.describe Rigor::Inference::ParameterInferenceCollector do
  def collect(*sources, max_rounds: described_class::DEFAULT_ROUNDS, workers: 0)
    Dir.mktmpdir do |dir|
      paths = sources.each_with_index.map do |source, i|
        path = File.join(dir, "f#{i}.rb")
        File.write(path, source)
        path
      end
      described_class.collect(files: paths, environment: Rigor::Environment.default,
                              max_rounds: max_rounds, workers: workers)
    end
  end

  it "infers a parameter from a concrete-arg implicit-self call site" do
    table = collect(<<~RUBY)
      class Widget
        def name = "w"
      end
      class Processor
        def run = process(Widget.new)
        def process(item)
          item
        end
      end
    RUBY
    inferred = table.fetch(["Processor", :process, :instance])
    expect(inferred[:item].describe(:short)).to eq("Widget")
  end

  it "infers from a concrete-arg explicit-receiver call site" do
    table = collect(<<~RUBY)
      class Widget
        def name = "w"
      end
      class Driver
        def go(widget)
          widget.run(Widget.new)
        end
      end
      class Widget
        def run(item)
          item
        end
      end
    RUBY
    # `widget.run(Widget.new)` — widget is untyped, so the receiver does not resolve and this call is skipped; the test
    # asserts only that the collector does not crash and produces no false entry for `run`.
    expect(table[["Widget", :run, :instance]]).to be_nil
  end

  it "unions two distinct concrete arguments across call sites" do
    table = collect(<<~RUBY)
      class A; end
      class B; end
      class Hub
        def one = handle(A.new)
        def two = handle(B.new)
        def handle(x)
          x
        end
      end
    RUBY
    inferred = table.fetch(["Hub", :handle, :instance])
    expect(inferred[:x]).to be_a(Rigor::Type::Union)
    members = inferred[:x].members.map { |m| m.describe(:short) }.sort
    expect(members).to eq(%w[A B])
  end

  it "poisons a parameter passed an untyped argument (the fixpoint case → WD4)" do
    table = collect(<<~RUBY)
      class Processor
        def outer(item)
          process(item)
        end
        def process(item)
          item
        end
      end
    RUBY
    expect(table[["Processor", :process, :instance]]).to be_nil
  end

  it "poisons when even one of several call sites is untyped" do
    table = collect(<<~RUBY)
      class A; end
      class Hub
        def good = handle(A.new)
        def bad(item) = handle(item)
        def handle(x)
          x
        end
      end
    RUBY
    expect(table[["Hub", :handle, :instance]]).to be_nil
  end

  it "infers a leading required parameter even when trailing optional / keyword / block params follow" do
    table = collect(<<~RUBY)
      class A; end
      class Hub
        def run = handle(A.new, extra: 1)
        def handle(x, y = 1, **opts, &block)
          x
        end
      end
    RUBY
    inferred = table.fetch(["Hub", :handle, :instance])
    expect(inferred[:x].describe(:short)).to eq("A")
    # The trailing optional `y` is not inferred (extra positional args are not mapped).
    expect(inferred).not_to have_key(:y)
  end

  it "skips a call whose arity does not match the parameter count" do
    table = collect(<<~RUBY)
      class A; end
      class Hub
        def run = handle(A.new)
        def handle(x, z)
          x
        end
      end
    RUBY
    expect(table[["Hub", :handle, :instance]]).to be_nil
  end

  it "skips a splat argument (positional mapping is unsound)" do
    table = collect(<<~RUBY)
      class A; end
      class Hub
        def run
          args = [A.new]
          handle(*args)
        end
        def handle(x)
          x
        end
      end
    RUBY
    expect(table[["Hub", :handle, :instance]]).to be_nil
  end

  it "widens a literal argument to its nominal (a parameter is not a pinned literal)" do
    table = collect(<<~RUBY)
      class Hub
        def run = handle("text")
        def handle(x)
          x
        end
      end
    RUBY
    inferred = table.fetch(["Hub", :handle, :instance])
    expect(inferred[:x].describe(:short)).to eq("String")
  end

  it "propagates a parameter through a one-hop chain (WD5 fixpoint)" do
    source = <<~RUBY
      class A; end
      class Hub
        def entry = middle(A.new)
        def middle(x)
          inner(x)
        end
        def inner(y)
          y
        end
      end
    RUBY
    table = collect(source)
    # `middle.x` is concrete in round 1 (called with `A.new`); `inner.y` is only reachable in round 2, once `x` is
    # seeded so `inner(x)` types `x` as `A`.
    expect(table.fetch(["Hub", :middle, :instance])[:x].describe(:short)).to eq("A")
    expect(table.fetch(["Hub", :inner, :instance])[:y].describe(:short)).to eq("A")
  end

  it "does not propagate the chain at max_rounds: 1 (single-level)" do
    source = <<~RUBY
      class A; end
      class Hub
        def entry = middle(A.new)
        def middle(x)
          inner(x)
        end
        def inner(y)
          y
        end
      end
    RUBY
    table = collect(source, max_rounds: 1)
    expect(table.fetch(["Hub", :middle, :instance])[:x].describe(:short)).to eq("A")
    expect(table[["Hub", :inner, :instance]]).to be_nil
  end

  it "resolves a call site in a sibling file" do
    table = collect(<<~RUBY, <<~CALLER)
      class A; end
      class Hub
        def handle(x)
          x
        end
      end
    RUBY
      class Hub
        def run = handle(A.new)
      end
    CALLER
    inferred = table.fetch(["Hub", :handle, :instance])
    expect(inferred[:x].describe(:short)).to eq("A")
  end

  # P3-10 — the fork-parallel round is a pure performance change: its table MUST equal the sequential one.
  # The merge must reproduce cross-file union, cross-file poison (a poison in ANY slice wins), and the
  # over-cap poison across the merged total — so the fixture spreads all three across separate files.
  describe "fork-parallel equivalence (workers > 1)" do
    # `A.new` in one file, `B.new` in another → the merge must union across slices; a third file passes an
    # untyped argument → the merge must poison `handle` despite the concrete sites; and `solo`'s many
    # distinct-class args (one file) exercise a per-slice-vs-merged cap decision.
    let(:sources) do
      base = <<~RUBY
        class A; end
        class B; end
        class C; end
        class Hub
          def handle(x) = x
          def solo(y) = y
        end
      RUBY
      site_a = "class Hub\n  def one = handle(A.new)\nend\n"
      site_b = "class Hub\n  def two = handle(B.new)\nend\n"
      poison = "class Hub\n  def bad(item) = handle(item)\nend\n"
      solo   = "class Hub\n  def s1 = solo(A.new)\n  def s2 = solo(B.new)\n  def s3 = solo(C.new)\nend\n"
      [base, site_a, site_b, poison, solo]
    end

    it "produces the same table forked as sequential" do
      skip "fork unavailable on this platform" unless Process.respond_to?(:fork)

      sequential = collect(*sources, workers: 0)
      forked = collect(*sources, workers: 4)

      expect(forked).to eq(sequential)
    end

    it "reproduces cross-file poison from a single slice's untyped call site" do
      skip "fork unavailable on this platform" unless Process.respond_to?(:fork)

      table = collect(*sources, workers: 4)
      # `handle` is poisoned by the untyped `handle(item)` site even though A/B sites are concrete.
      expect(table[["Hub", :handle, :instance]]).to be_nil
      # `solo` unions its three concrete sites unaffected by the split.
      expect(table.fetch(["Hub", :solo, :instance])[:y].members.map { |m| m.describe(:short) }.sort)
        .to eq(%w[A B C])
    end
  end
end
