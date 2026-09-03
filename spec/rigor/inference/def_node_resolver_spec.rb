# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "prism"
require "rigor/inference/def_node_resolver"
require "rigor/inference/def_handle"

# ADR-85 WD3 — the per-run def-node parse memo. The load-bearing property is identity: a handle must resolve to
# ONE stable `Prism::DefNode` object for the run, because the ADR-84 return memo keys on def-node identity and a
# fresh parse per resolution would fragment it.
RSpec.describe Rigor::Inference::DefNodeResolver do
  def find_def(root, name)
    return root if root.is_a?(Prism::DefNode) && root.name == name

    root.compact_child_nodes.each do |child|
      found = find_def(child, name)
      return found if found
    end
    nil
  end

  def def_handle(**)
    Rigor::Inference::DefHandle.new(**)
  end

  def write_and_handle(dir, name: :bar, fingerprint: "fp", nesting: ["Foo"])
    path = File.join(dir, "a.rb")
    File.write(path, "class Foo\n  def bar = 1\n  def baz = 2\nend\n")
    node = find_def(Prism.parse(File.read(path)).value, name)
    [path, def_handle(path: path, node_id: node.node_id, name: name.to_s, fingerprint: fingerprint,
                      nesting: nesting)]
  end

  it "resolves a handle to one stable node object for the run (identity)" do
    Dir.mktmpdir do |dir|
      path, handle = write_and_handle(dir)
      described_class.with_run do
        first = described_class.resolve(handle)
        second = described_class.resolve(handle)
        # A second handle carrying the same (path, node_id) — a different consumer's table entry.
        twin_handle = def_handle(
          path: path, node_id: handle.node_id, name: "bar", fingerprint: "z", nesting: ["Foo"]
        )
        twin = described_class.resolve(twin_handle)

        expect(first).to be_a(Prism::DefNode)
        expect(first.name).to eq(:bar)
        expect(second).to equal(first)
        expect(twin).to equal(first)
      end
    end
  end

  it "mints a fresh identity in a separate run scope (the run boundary the memo respects)" do
    Dir.mktmpdir do |dir|
      _path, handle = write_and_handle(dir)
      a = described_class.with_run { described_class.resolve(handle) }
      b = described_class.with_run { described_class.resolve(handle) }
      expect(a).to be_a(Prism::DefNode)
      expect(a).not_to equal(b)
    end
  end

  it "returns a live node unchanged (non-handle passthrough, the cold / re-walked file path)" do
    node = find_def(Prism.parse("def solo = 1").value, :solo)
    described_class.with_run do
      expect(described_class.resolve(node)).to equal(node)
    end
    expect(described_class.resolve(nil)).to be_nil
  end

  it "falls back to the same-named def when the node_id cross-check misses (never silent)" do
    Dir.mktmpdir do |dir|
      path, handle = write_and_handle(dir, name: :baz)
      # A stale node_id that does not exist in the file → cross-check miss → by-name fallback.
      stale = def_handle(path: path, node_id: 999_999, name: "baz", fingerprint: handle.fingerprint,
                         nesting: ["Foo"])
      described_class.with_run do
        node = described_class.resolve(stale)
        expect(node).to be_a(Prism::DefNode)
        expect(node.name).to eq(:baz)
      end
    end
  end

  it "resolves without a run scope (runner-less probe) by parsing directly" do
    Dir.mktmpdir do |dir|
      _path, handle = write_and_handle(dir)
      node = described_class.resolve(handle)
      expect(node).to be_a(Prism::DefNode)
      expect(node.name).to eq(:bar)
    end
  end

  # Issue #707 — the chain #681 records against the DECLARATION cannot ride the discovery table across a
  # bundle: that table is keyed by node identity and the node here is minted by this module's own parse. So
  # the handle carries it and the resolver re-attaches it to the node it hands back.
  describe ".rehydrated_nesting" do
    it "answers the handle's chain for the node the resolution minted" do
      Dir.mktmpdir do |dir|
        _path, handle = write_and_handle(dir, nesting: ["Admin::CompactMaker"])
        described_class.with_run do
          node = described_class.resolve(handle)
          expect(described_class.rehydrated_nesting(node)).to eq(["Admin::CompactMaker"])
        end
      end
    end

    it "answers nil for a node it never minted, so a live node keeps reading the discovery table" do
      node = find_def(Prism.parse("class Foo\n  def bar = 1\nend\n").value, :bar)
      described_class.with_run do
        expect(described_class.resolve(node)).to equal(node)
        expect(described_class.rehydrated_nesting(node)).to be_nil
      end
    end

    it "records nothing for a top-level def's absent chain, keeping the peel fallback" do
      Dir.mktmpdir do |dir|
        _path, handle = write_and_handle(dir, nesting: nil)
        described_class.with_run do
          node = described_class.resolve(handle)
          expect(node).to be_a(Prism::DefNode)
          expect(described_class.rehydrated_nesting(node)).to be_nil
        end
      end
    end

    it "does not leak across the run boundary the node identity itself respects" do
      Dir.mktmpdir do |dir|
        _path, handle = write_and_handle(dir, nesting: ["Foo"])
        first = described_class.with_run do
          node = described_class.resolve(handle)
          expect(described_class.rehydrated_nesting(node)).to eq(["Foo"])
          node
        end
        described_class.with_run { expect(described_class.rehydrated_nesting(first)).to be_nil }
      end
    end
  end
end
