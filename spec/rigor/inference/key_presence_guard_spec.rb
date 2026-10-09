# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/key_presence_guard"
require "rigor/scope"
require "rigor/type"

# Unit coverage for {Rigor::Inference::KeyPresenceGuard}'s address and invalidation primitives. The regression load is
# carried by `spec/integration/computed_key_presence_guard_spec.rb`; this file pins the decisions one at a time.
RSpec.describe Rigor::Inference::KeyPresenceGuard do
  let(:scope) { Rigor::Scope.empty }
  let(:present) { Rigor::Type::Combinator.constant_of(true) }
  let(:chain_key) { key_of("prop = 1\nprop.column_type\n") }
  let(:guarded) { scope.with_indexed_narrowing(:const, :MAP, chain_key, present) }

  def last_node(source) = Prism.parse(source).value.statements.body.last

  def key_of(source) = described_class.key_expr(last_node(source))

  def survives?(source, guard_scope = guarded, key = chain_key)
    post = described_class.invalidate_after_call(last_node(source), guard_scope)
    !post.indexed_narrowing(:const, :MAP, key).nil?
  end

  def survives_write?(source)
    post = described_class.invalidate_after_write(last_node(source), guarded)
    !post.indexed_narrowing(:const, :MAP, chain_key).nil?
  end

  it "addresses a local, an ivar and a reader chain, and two spellings of one chain equally" do
    expect(key_of("k = 1\nk\n").path).to eq([%i[local k]])
    expect(key_of("@k\n").path).to eq([%i[ivar @k]])
    expect(chain_key).to eq(key_of("prop = 2\nprop.column_type\n"))
  end

  it "declines a literal key and a chain hop that is not a plain, idempotent reader" do
    ["k = 1\nk.fetch(:a)\n", "k = 1\nk&.name\n", "k = 1\nk.name!\n", "column_type\n", ":k\n", "q = 1\nq.shift\n",
     "q = 1\nq.pop\n", "io = 1\nio.gets\n", "e = 1\ne.next\n", "q = 1\nq.first.shift\n"].each do |src|
      expect(key_of(src)).to be_nil, src
    end
  end

  it "survives re-reading the key chain, reads of the receiver and calls on unrelated receivers" do
    expect(survives?("prop = 1\nprop.column_type\n")).to be(true)
    expect(survives?("other = 1\nother.reload\n")).to be(true)
    expect(survives?("MAP.fetch(:a)\n")).to be(true)
    expect(survives?("prop = 1\noverridden?(prop)\n")).to be(true)
    expect(survives?("log(MAP[:a])\n")).to be(true)
  end

  it "drops on another call rooted at the key's variable, at any depth" do
    expect(survives?("prop = 1\nprop.reload\n")).to be(false)
    expect(survives?("prop = 1\nprop.column_type = :x\n")).to be(false)
    expect(survives?("prop = 1\nprop.owner.touch\n")).to be(false)
  end

  it "drops on a write, a mutator or any non-reading call against the guarded receiver" do
    expect(survives?("MAP[:other] = 1\n")).to be(false)
    expect(survives?("MAP.delete(:a)\n")).to be(false)
    expect(survives?("MAP.send(:delete, :a)\n")).to be(false)
    expect(survives?("MAP.fetch(:a) { 1 }\n")).to be(false)
  end

  it "drops when the receiver escapes as an argument or into a block" do
    expect(survives?("zap(MAP)\n")).to be(false)
    expect(survives?("zap([MAP])\n")).to be(false)
    expect(survives?("list = 1\nlist.each { MAP.clear }\n")).to be(false)
  end

  it "drops when a write aliases the receiver or the key's root" do
    expect(survives_write?("g = MAP\n")).to be(false)
    expect(survives_write?("prop = 1\nj = prop\n")).to be(false)
    expect(survives_write?("x = MAP[:a]\n")).to be(true)
  end

  it "drops on a self call, or a call handed self, only when an instance variable is involved" do
    expect(survives?("refresh\n")).to be(true)
    ivar_key = key_of("@k\n")
    ivar_guard = scope.with_indexed_narrowing(:const, :MAP, ivar_key, present)
    expect(survives?("refresh\n", ivar_guard, ivar_key)).to be(false)
    expect(survives?("other = 1\nother.notify(self)\n", ivar_guard, ivar_key)).to be(false)
  end

  it "drops when the key's root variable is rebound" do
    expect(guarded.with_local(:prop, present).indexed_narrowing(:const, :MAP, chain_key)).to be_nil
    expect(guarded.with_local(:other, present).indexed_narrowing(:const, :MAP, chain_key)).not_to be_nil
  end

  it "neither records nor reads a guard inside without_guards" do
    node = last_node("MAP = { a: 1 }\nk = 1\nMAP.key?(k)\n")
    described_class.without_guards { expect(described_class.record(node, scope)).to be_nil }
    expect(described_class.off?).to be(false)
  end
end
