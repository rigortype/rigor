# frozen_string_literal: true

require "spec_helper"

# ADR-129 G2 — the class-graph cache's "user def" and "self pure" buckets get no hit in CI's audited `rigor check lib`,
# so this program reaches a hit in each under `RIGOR_MEMO_AUDIT=1`: an implicit-self call whose answer comes from the
# user-def bucket, and a foldable Struct instance whose self-call purity is asked twice. A key defect in either bucket
# then fails here as a MemoAudit mismatch: `Foo` and `Qux` each define their own `a`, so a key that drops the class
# serves one class's def to the other.
RSpec.describe "MemoAudit reaches the class-graph user-def and self-pure buckets", type: :runner do
  around do |example|
    Rigor::Inference::MemoAudit.enable!
    example.run
  ensure
    Rigor::Inference::MemoAudit.disable!
  end

  let(:source) do
    <<~RUBY
      class Foo
        def a = 1
        def b = a + 1
        def d = zork
        def e = zork
      end

      class Bar < Foo
        def f = a
        def g = a
        def h = zork
      end

      Point = Struct.new(:x, :y) do
        def sum = x + y
        def twice = sum * 2
      end

      pt = Point.new(1, 2)
      pt.twice
      pt.twice
      Point.new(3, 4).twice

      def helper = 1

      class Baz < Foo
        def m = helper
        def n = helper
        def o = a.to_s
      end

      class Qux
        def a = "s"
        def p = a
        def q = a
        def r = zork
      end
    RUBY
  end

  it "audits a hit of each bucket without a mismatch" do
    hits = Hash.new(0)
    allow(Rigor::Inference::MemoAudit).to receive(:check).and_wrap_original do |original, label, *rest, &block|
      hits[label] += 1 unless Rigor::Inference::MemoAudit.suspended?
      original.call(label, *rest, &block)
    end
    analyze(source)
    expect(hits.values_at("class graph user def", "class graph self pure")).to all(be_positive)
  end

  # The user-def bucket keyed by class and method: two classes that each define `a` answer different defs, so a key
  # that drops the class would serve one's def to the other, and the audited hit raises.
  it "audits the user-def bucket per class" do
    tree = Prism.parse("class Foo\n  def a = 1\nend\nclass Qux\n  def a = \"s\"\nend\nFoo\n").value
    index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: Rigor::Scope.empty)
    typer = Rigor::Inference::ExpressionTyper.new(scope: index[tree.statements.body.last])
    resolve = ->(klass) { typer.send(:resolve_user_def_with_owner, klass, :a) }
    foo = resolve.call("Foo")
    qux = resolve.call("Qux")
    expect([resolve.call("Foo"), resolve.call("Qux")]).to eq([foo, qux])
    expect(foo.last).to eq("Foo")
    expect(qux.last).to eq("Qux")
  end
end
