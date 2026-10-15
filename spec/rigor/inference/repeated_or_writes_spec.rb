# frozen_string_literal: true

require "spec_helper"

# The index `||=` sites a block-return pass marks as ones an earlier run of a repeating body may have filled. The
# integration behaviour — what a marked site answers — is pinned in `block_return_scope_threading_spec.rb`; this
# file pins which sites the scan picks.
RSpec.describe Rigor::Inference::RepeatedOrWrites do
  let(:scope) { Rigor::Scope.empty.with_local(:cache, Rigor::Type::Combinator.untyped) }

  def block_of(source)
    call = Prism.parse(source, scopes: [[:cache]]).value.statements.body.first
    call.block
  end

  def or_writes(block)
    found = []
    Rigor::Source::NodeWalker.each(block) { |node| found << node if node.is_a?(Prism::IndexOrWriteNode) }
    found
  end

  def generic(source)
    block = block_of(source)
    [described_class.sites(block, {}, scope).at(nil), or_writes(block)]
  end

  def positional(source, element_count)
    block = block_of(source)
    elements = Array.new(element_count) { |index| Rigor::Type::Combinator.constant_of(index) }
    [described_class.sites(block, {}, scope, element_types: elements), or_writes(block)]
  end

  it "marks nothing in a body that holds no index `||=`" do
    expect(described_class.sites(block_of("xs.map { |x| x + 1 }"), {}, scope)).to equal(described_class::NO_MARKS)
  end

  it "never marks the per-element fold's first position" do
    marks, sites = positional("xs.map { |e| cache[:k] ||= e }", 3)
    expect([marks.at(0), marks.at(1), marks.at(2)]).to eq([[], sites, sites])
  end

  it "leaves an isolated site unmarked under the generic pass, and marks two sites sharing a slot" do
    isolated, = generic("xs.map { |e| cache[e] ||= e }")
    shared, sites = generic("xs.map { |e| e ? (cache[:k] ||= 1) : (cache[:k] ||= 2) }")
    expect([isolated, shared]).to eq([[], sites])
  end

  it "does not mark a site on a receiver that is fresh at every run" do
    marks, = positional("xs.map { |e| Hash.new[:k] ||= e }", 2)
    expect(marks.at(1)).to eq([])
  end

  it "does not look inside a nested `def` body, which runs only when called" do
    marks, = positional("xs.map { |e| def helper = (@memo[:k] ||= 1); e }", 2)
    expect(marks).to equal(described_class::NO_MARKS)
  end

  it "walks a body whose `||=` sits in a heredoc, which the body's own source slice leaves out" do
    source = "xs.map { |e| <<~S.strip }\n  \#{cache[:k] ||= e}\nS\n"
    marks, sites = positional(source, 2)
    expect([block_of(source).body.slice.include?("||="), sites.size, marks.at(1)]).to eq([false, 1, sites])
  end

  # Issue #1885 — the straight-line marks: a site whose slot a store earlier in the same body may have filled.
  describe ".straight_line_sites" do
    def straight(source, entry = Rigor::Scope.empty)
      body = Prism.parse(source, scopes: [%i[cache cond k]]).value.statements
      [described_class.straight_line_sites(body, entry), or_writes(body)]
    end

    def hash_entry = Rigor::Scope.empty.with_local(:cache, Rigor::Type::Combinator.nominal_of("Hash"))

    it "marks a site after a conditional store into the same slot, and not the store itself" do
      marks, sites = straight("cache[:k] ||= :e if cond\n(cache[:k] ||= :f).itself")
      expect(marks).to eq([sites.last])
    end

    it "counts a plain `[]=` by its key, and a mutator as writing any slot" do
      assigned, assigned_sites = straight("cache[:k] = :e if cond\n(cache[:k] ||= :f)")
      other_key, = straight("cache[:a] = :e if cond\n(cache[:b] ||= :f)")
      # `insert(0, x)` shifts every element, so its first argument is no key: slot 1 may now hold the old slot 0.
      inserted, inserted_sites = straight("cache.insert(0, :e) if cond\n(cache[1] ||= :f)")
      expect([assigned, other_key, inserted]).to eq([assigned_sites, [], inserted_sites])
    end

    it "counts a store above the site's object only when it may install a shared one" do
      shared, shared_sites = straight("cache[:a] = k if cond\n(cache[:a][:b] ||= :f)")
      fresh, = straight("cache[:a] = {} if cond\n(cache[:a][:b] ||= :f)")
      expect([shared, fresh]).to eq([shared_sites, []])
    end

    it "does not count a store after the site" do
      marks, sites = straight("(cache[:k] ||= :f).itself\ncache[:k] ||= :e if cond")
      expect(marks).to eq([sites.last])
    end

    it "does not count a store whose literal key differs from the site's" do
      symbols, = straight("cache[:a] ||= 1 if cond\n(cache[:b] ||= 2)")
      indices, = straight("cache[0] ||= 1 if cond\n(cache[1] ||= 2)")
      expect([symbols, indices]).to eq([[], []])
    end

    it "counts a store whose key may name the same slot" do
      mixed, mixed_sites = straight("cache[:a] ||= 1 if cond\n(cache[\"a\"] ||= 2)")
      negative, negative_sites = straight("cache[-1] ||= 1 if cond\n(cache[0] ||= 2)")
      computed, computed_sites = straight("cache[k] ||= 1 if cond\n(cache[:a] ||= 2)")
      expect([mixed, negative, computed]).to eq([[mixed_sites.last], [negative_sites.last], [computed_sites.last]])
    end

    it "does not count a store in the other arm of an `if`, outside any loop" do
      marks, = straight("if cond then cache[:k] ||= :e else (cache[:k] ||= :f) end")
      expect(marks).to eq([])
    end

    it "counts a store in the other arm when a loop runs both arms in turn" do
      marks, sites = straight("for x in cond do x ? (cache[:k] ||= :e) : (cache[:k] ||= :f) end")
      expect(marks).to eq([sites.last])
    end

    it "counts a store in a block that runs before the site" do
      marks, sites = straight("1.tap { cache[:k] ||= :e if cond }\n(cache[:k] ||= :f)")
      expect(marks).to eq([sites.last])
    end

    it "does not look inside a nested `def` body" do
      marks, = straight("@memo[:k] ||= :e if cond\ndef helper = (@memo[:k] ||= 1)")
      expect(marks).to eq([])
    end

    it "does not count a remover on a root the body binds to a new `Hash`, nor on a parameter typed `Hash`" do
      local, = straight("c = {}\nc.delete(k) if cond\n(c[k] ||= :f)")
      parameter, = straight("cache.delete(k) if k.nil?\n(cache[k] ||= :f)", hash_entry)
      expect([local, parameter]).to eq([[], []])
    end

    it "counts a remover on an array, an untyped root, or a root the body also binds to something else" do
      array, array_sites = straight("c = []\nc.delete(k) if cond\n(c[0] ||= :f)")
      untyped, untyped_sites = straight("cache.delete(k) if k.nil?\n(cache[k] ||= :f)")
      rebound_source = "cache = [] if cond\ncache.delete(k) if k.nil?\n(cache[k] ||= :f)"
      rebound, rebound_sites = straight(rebound_source, hash_entry)
      expect([array, untyped, rebound]).to eq([array_sites, untyped_sites, rebound_sites])
    end

    it "tells literal keys of different classes apart on a `Hash` root only" do
      source = "cache[\"k\"] = 1 if cond\ncache[1] = 1 if cond\n(cache[:k] ||= 2)\n(cache[1.0] ||= 2)"
      on_hash, = straight(source, hash_entry)
      untyped, untyped_sites = straight("cache[1] = 1 if cond\n(cache[1.0] ||= 2)")
      expect([on_hash, untyped]).to eq([[], [untyped_sites.last]])
    end

    it "tells two different `String` keys apart on any root" do
      marks, = straight("cache[\"a\"] ||= 1 if cond\n(cache[\"b\"] ||= 2)")
      expect(marks).to eq([])
    end

    it "counts a store above the site that installs a non-empty literal" do
      marks, sites = straight("cache[:a] = { k: :e } if cond\ncache[:a] ||= Hash.new\n(cache[:a][:k] ||= :f)")
      expect(marks).to eq(sites)
    end

    it "counts a store below the site through its slot, and not one through another slot" do
      through, through_sites = straight("cache[:a][:k] = 1 if cond\n(cache[:a] ||= 2)")
      other, = straight("cache[:x][:k] = 1 if cond\n(cache[:a] ||= 2)")
      expect([through, other]).to eq([through_sites, []])
    end

    it "does not count a store in the other arm of an `unless`" do
      marks, = straight("unless cond then cache[:k] ||= :e else (cache[:k] ||= :f) end")
      expect(marks).to eq([])
    end

    it "counts a store in the other arm when a `while` loop runs both arms in turn" do
      marks, sites = straight("while cond do k ? (cache[:k] ||= :e) : (cache[:k] ||= :f) end")
      expect(marks).to eq([sites.last])
    end

    it "lets the root's kind decide only for the root's own slots and its own removers" do
      key, key_sites = straight("c = {}\nc[:a][\"k\"] = 1 if cond\n(c[:a][:k] ||= 2)")
      inner, inner_sites = straight("c = {}\nc[:a].delete(:x) if cond\n(c[:a][:b][:k] ||= 2)")
      root, = straight("c = {}\nc.delete(:x) if cond\n(c[:a][:k] ||= 2)")
      untyped, untyped_sites = straight("cache.delete(:x) if cond\n(cache[:a][:k] ||= 2)")
      expect([key, inner, root, untyped]).to eq([key_sites, inner_sites, [], untyped_sites])
    end
  end
end
