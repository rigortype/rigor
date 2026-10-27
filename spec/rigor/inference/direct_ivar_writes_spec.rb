# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #2039 — the instance variables an implicit-self or `self.` call's callee assigns a value that can be `nil` by
# its syntax alone, read without the #1596 proof.
RSpec.describe Rigor::Inference::DirectIvarWrites do
  let(:project) { Rigor::Scope.empty(environment: Rigor::Environment.for_project(signature_paths: [])) }

  # The answer for the `target` call in `Holder#probe`, with `body` the rest of `Holder`'s body and `prelude` the
  # code before the class.
  def writes(body, target: "r", prelude: "")
    source = "#{prelude}\nclass Holder\n#{body}\n  def probe = #{target}\nend\n"
    tree = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: project)
    probe = nil
    tree.breadth_first_search do |node|
      probe = node if node.is_a?(Prism::DefNode) && node.name == :probe
      false
    end
    call = probe.body.is_a?(Prism::StatementsNode) ? probe.body.body.last : probe.body
    described_class.of(call, index[call])
  end

  it "counts a nil literal, a safe-navigation call and a conditional with a missing or nil arm" do
    ["def r = (@tag = nil)", "def r = (@tag = @peer&.tag)", "def r = (@tag = (@peer if ready?))",
     "def r = (@tag = ready? ? 'a' : nil)", "def r = (@tag = (case @k when 1 then 'a' end))",
     "def r = (@tag = (unless ready? then 'a' end))", "def r = (@tag = nil if ready?)",
     "def r = (@tag = (if ready? then 'a' elsif done? then nil else 'b' end))"].each do |body|
      expect(writes(body)).to eq(Set[:@tag]), body
    end
  end

  it "does not count a literal, a method call's result, a parameter or a conditional whose arms are all values" do
    ["def r = (@tag = 'a')", "def r = (@tag = @tag.strip)", "def r(v) = (@tag = v)", "def r = (@tag = format('x'))",
     "def r = (@tag = ready? ? 'a' : 'b')", "def r = (@tag = (case @k when 1 then 'a' else 'b' end))",
     "def r = (@count += 1)"].each do |body|
      expect(writes(body)).to eq(Set[]), body
    end
  end

  it "counts an `||=` or `&&=` write only when its value qualifies" do
    expect(writes("def r = (@tag ||= nil)")).to eq(Set[:@tag])
    expect(writes("def r = (@tag &&= @tag&.strip)")).to eq(Set[:@tag])
    expect(writes("def r = (@tag ||= 'x')")).to eq(Set[])
    expect(writes("def r = (@tag &&= @tag.strip)")).to eq(Set[])
  end

  it "judges each target of a multiple assignment by its own value, and counts no splat or unknown value" do
    expect(writes("def r = (@a, @tag = 1, 's')")).to eq(Set[])
    expect(writes("def r = (@a, @tag = 1, nil)")).to eq(Set[:@tag])
    expect(writes("def r = (@a, @tag = [nil, 's'])")).to eq(Set[:@a])
    expect(writes("def r = (@a, @tag = 1, *rest)")).to eq(Set[])
    expect(writes("def r = (@a, @tag = pair)")).to eq(Set[])
  end

  it "reads a block's body but not a lambda's, a nested def's or a class body's" do
    expect(writes("def r = [1].each { @tag = nil }")).to eq(Set[:@tag])
    expect(writes("def r = (f = -> { @tag = nil }; f.arity)")).to eq(Set[])
    expect(writes("def r\n  def inner = (@tag = nil)\nend")).to eq(Set[])
  end

  it "follows the callee's own self-calls, and stops past the def budget" do
    expect(writes("def clear = (@tag = nil)\n  def r = clear")).to eq(Set[:@tag])
    expect(writes("def clear = (@tag = nil)\n  def r = self.clear")).to eq(Set[:@tag])
    chain = (1..8).map { |i| "def s#{i} = s#{i + 1}" }.join("\n") + "\ndef s9 = (@tag = nil)"
    expect(writes(chain, target: "s2")).to eq(Set[:@tag])
    expect(writes(chain, target: "s1")).to eq(Set[])
  end

  it "falls back to a project module the class includes" do
    prelude = "module Resetter\n  def r = (@tag = nil)\nend"
    expect(writes("include Resetter", prelude: prelude)).to eq(Set[:@tag])
  end

  it "does not take a singleton def as the callee" do
    expect(writes("def self.r = (@tag = nil)")).to eq(Set[])
  end
end
