# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/captured_locals"
require "rigor/scope"
require "rigor/type"

# Unit-level coverage for {Rigor::Inference::CapturedLocals}. The consumer — the per-element block fold's entry
# bindings — is exercised end-to-end by `spec/rigor/inference/block_return_scope_threading_spec.rb`; this file
# pins which nodes count as a rebind or a site.
RSpec.describe Rigor::Inference::CapturedLocals do
  # The fixture binds its locals first so Prism parses them as reads, not method calls; the block under test
  # is the one on the LAST statement.
  def block_of(source)
    Prism.parse(source).value.statements.body.last.block
  end

  def scope_binding(*names)
    names.reduce(Rigor::Scope.empty) { |acc, name| acc.with_local(name, Rigor::Type::HashShape.new) }
  end

  describe ".writes" do
    def written(source, *names)
      described_class.writes(block_of(source), scope_binding(*names))
    end

    it "collects a captured local rebound in the body and inside a nested block" do
      source = "a = 1\nb = 2\n[1].each { |k| a = k; [2].each { |j| b += j } }\n"
      expect(written(source, :a, :b)).to eq(%i[a b])
    end

    it "excludes a name the block's own parameter shadows" do
      expect(written("a = 1\n[1].each { |a| a = 2 }\n", :a)).to be_empty
    end

    it "excludes a write a nested block's parameter shadows" do
      # `a = k` rebinds the inner block's `|a|`, not the outer `a`; `.content_mutations` excludes `a << k` there
      # on the same terms.
      source = "a = [1]\n[1].each { |k| [[]].each { |a| a = k; a << k } }\n"
      expect(written(source, :a)).to be_empty
      expect(described_class.content_mutations(block_of(source), scope_binding(:a))).to be_empty
    end

    it "excludes a write a nested block-local or lambda parameter shadows" do
      source = "a = 1\n[1].each { |k| [2].each { |j; a| a = j }; ->(a) { a = k } }\n"
      expect(written(source, :a)).to be_empty
    end

    it "excludes a write inside a nested def or class body" do
      source = "z = 0\n[1].each { |k| def helper; z = 5; end; class Foo; z = 1; end; class << self; z = 2; end }\n"
      expect(written(source, :z)).to be_empty
    end

    it "still collects a write in a def receiver, a superclass or a singleton-class target" do
      # Each runs in the enclosing scope, not the one the `def` or class body opens.
      source = "a = 1\nb = 2\nc = 3\n[1].each { |k| def (a = k).m; end; class Foo < (b = Object); end; " \
               "class << (c = k); end }\n"
      expect(written(source, :a, :b, :c)).to eq(%i[a b c])
    end

    it "excludes a mutation inside a nested def, but not one in its receiver" do
      source = "h = {}\n[1].each { |k| def helper; h = {}; h[:a] = 1; end; def (h[:b] = k).m; end }\n"
      expect(described_class.content_mutations(block_of(source), scope_binding(:h)).transform_values(&:size))
        .to eq(h: 1)
    end

    it "still collects the outer local a sibling write reaches past the shadowing block" do
      source = "a = 1\n[1].each { |k| [2].each { |a| a = k }; a = k }\n"
      expect(written(source, :a)).to eq(%i[a])
    end
  end

  describe ".content_mutations" do
    def site_classes(source, *names)
      described_class.content_mutations(block_of(source), scope_binding(*names))
                     .transform_values { |sites| sites.map(&:class) }
    end

    it "collects a `[]=` call, an index compound write and an adder call on a captured local, in source order" do
      source = "h = {}\n[1].each { |k| h[k] = 1; h[k] += 1; h << [k, 1] }\n"
      expect(site_classes(source, :h))
        .to eq(h: [Prism::CallNode, Prism::IndexOperatorWriteNode, Prism::CallNode])
    end

    it "collects every variable a selected receiver can evaluate to" do
      source = "a = []\nb = []\nf = true\n[1].each { |e| (f ? a : b) << e }\n"
      expect(site_classes(source, :a, :b, :f).keys).to eq(%i[a b])
    end

    it "collects a site inside a nested block" do
      source = "h = {}\n[1].each { |k| [2].each { |j| h[j] ||= k } }\n"
      expect(site_classes(source, :h)).to eq(h: [Prism::IndexOrWriteNode])
    end

    it "collects a multi-assign index target" do
      source = "h = {}\n[1].each { |k| h[k], x = 1, 2 }\n"
      expect(site_classes(source, :h)).to eq(h: [Prism::IndexTargetNode])
    end

    it "excludes a name a block parameter shadows" do
      source = "h = {}\n[{}].each { |h| h[:a] = 1 }\n"
      expect(site_classes(source, :h)).to be_empty
    end

    it "excludes a local the call-site scope does not bind" do
      source = "h = {}\n[1].each { |k| h[k] = 1 }\n"
      expect(site_classes(source)).to be_empty
    end

    it "ignores reads and non-mutating calls" do
      source = "h = {}\n[1].each { |k| h[k]; h.fetch(k); h.merge(k => 1) }\n"
      expect(site_classes(source, :h)).to be_empty
    end

    it "collects a mutator on an element read rooted at a captured local" do
      source = "a = []\n[1].each { |e| a[0] << e; a.first.push(e) }\n"
      expect(site_classes(source, :a)).to eq(a: [Prism::CallNode, Prism::CallNode])
    end

    it "excludes an element read rooted at a nested block's parameter" do
      source = "a = []\n[1].each { |e| [[[]]].each { |a| a[0] << e } }\n"
      expect(site_classes(source, :a)).to be_empty
    end

    it "answers empty for a block with no body" do
      expect(site_classes("h = {}\n[1].each { |k| }\n", :h)).to be_empty
    end
  end

  # Issue #1412 — the loop-body sibling of `.content_mutations`: a loop body introduces no name, so every local the
  # entry scope binds counts, on the same depth terms.
  describe ".loop_content_mutations" do
    def loop_sites(source, *names)
      statements = Prism.parse(source).value.statements.body.last.statements
      described_class.loop_content_mutations(statements, scope_binding(*names))
                     .transform_values { |sites| sites.map(&:class) }
    end

    it "collects a mutator and an index store on a local the loop entry binds" do
      source = "a = []\nh = {}\nwhile a.size < 3\n  a << 1\n  h[:k] = 2\nend\n"
      expect(loop_sites(source, :a, :h)).to eq(a: [Prism::CallNode], h: [Prism::CallNode])
    end

    it "excludes a nested block's parameter that shares the name, and a nested def's own local" do
      source = "a = []\nwhile a.empty?\n  [[]].each { |a| a << 1 }\n  def helper; a = []; a << 2; end\nend\n"
      expect(loop_sites(source, :a)).to be_empty
    end

    it "excludes a local the entry scope does not bind" do
      expect(loop_sites("a = []\nwhile a.empty?\n  a << 1\nend\n")).to be_empty
    end
  end

  # Issue #1412 — the statement pass's pre-scan. It may answer true where `.writes` and `.content_mutations` both
  # come back empty, but never false where either finds something: each shape below is one they collect (the
  # callee store once `add_to` resolves to a method that mutates its parameter).
  describe ".may_touch_capture?" do
    {
      "rebind" => "a = 1\n[1].each { |k| a = k }\n",
      "nested rebind" => "a = 1\n[1].each { |k| [2].each { a += k } }\n",
      "ivar rebind" => "a = 1\n[1].each { |k| @n = k }\n",
      "mutator" => "a = []\n[1].each { |k| a << k }\n",
      "index store" => "a = {}\n[1].each { |k| a[k] ||= 1 }\n",
      "element mutator" => "a = [[]]\n[1].each { |k| a[0].push(k) }\n",
      "callee store" => "a = []\n[1].each { |k| add_to(a, k) }\n"
    }.each do |label, source|
      it "answers true for a #{label}" do
        expect(described_class.may_touch_capture?(block_of(source).body, scope_binding(:a))).to be(true)
      end
    end

    it "answers false for a body that only reads captures and writes its own locals" do
      block = block_of("a = []\n[1].each { |k| t = a.size + k; puts t.to_s }\n")
      expect(described_class.may_touch_capture?(block.body, scope_binding(:a))).to be(false)
    end
  end

  # Issue #1302 — the miss answer a mark records rides the rebind `.bind` makes across iterations. An
  # iteration's own mark comes without its answer, so once one joins the binding's, the answer is dropped.
  describe ".bind" do
    let(:cause) { Rigor::Inference::OptimisticOrigin::IMPLICITLY_RETURNS_NIL }
    let(:type) { Rigor::Type::Combinator.constant_of(false) }

    it "keeps the recorded miss answer of a local and an ivar when no iteration marked them" do
      marked = Rigor::Scope.empty.with_local(:x, type).with_optimistic_local(:x, cause, miss: false)
                           .with_ivar(:@y, type).with_optimistic_ivar(:@y, cause, miss: nil)
      bound = described_class.bind(described_class.bind(marked, "x", type), "@y", type)

      expect([bound.optimistic_local_miss(:x), bound.optimistic_ivar_miss(:@y)]).to eq([false, nil])
    end

    # End to end, the per-element fold floors a rebound captured name to `Dynamic[top]` on its later passes
    # (#1233), so the dropped answer is not yet visible through a block's type; this pins the rule directly.
    it "drops the answer of a local and an ivar once an iteration's own mark joins the binding" do
      marked = Rigor::Scope.empty.with_local(:x, type).with_optimistic_local(:x, cause, miss: false)
                           .with_ivar(:@y, type).with_optimistic_ivar(:@y, cause, miss: false)
      bound = described_class.bind(described_class.bind(marked, "x", type, optimistic: cause), "@y", type,
                                   optimistic: cause)

      expect([bound.optimistic_local(:x), bound.optimistic_ivar(:@y)]).to eq([cause, cause])
      expect(bound.optimistic_local_miss(:x)).to be(Rigor::Inference::OptimisticOrigin::UNKNOWN_MISS)
      expect(bound.optimistic_ivar_miss(:@y)).to be(Rigor::Inference::OptimisticOrigin::UNKNOWN_MISS)
    end
  end
end
