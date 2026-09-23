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
end
