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
end
