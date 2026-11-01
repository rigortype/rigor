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
     "def r = (@tag = (if ready? then 'a' elsif done? then nil else 'b' end))",
     "def r = (@tag = (if ready? then else 'b' end))"].each do |body|
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
    expect(writes("def r = (@a, @b, @tag = 1, 2)")).to eq(Set[:@tag])
    expect(writes("def r = (@a, @tag = 1, *rest)")).to eq(Set[])
    expect(writes("def r = (@a, @tag = *pre, nil)")).to eq(Set[])
    expect(writes("def r = (@a, @tag = pair)")).to eq(Set[])
  end

  # Issue #2482 — a `case ... in` with no `else` raises NoMatchingPatternError instead of answering `nil`.
  it "counts a `case ... in` with a nil arm or an empty `else`, and not one with no `else`" do
    expect(writes("def r = (@tag = case @k\n in Integer then nil\n else 'b'\n end)")).to eq(Set[:@tag])
    expect(writes("def r = (@tag = case @k\n in Integer then 'a'\n else\n end)")).to eq(Set[:@tag])
    expect(writes("def r = (@tag = case @k\n in Integer then 'a'\n end)")).to eq(Set[])
    expect(writes("def r = (@tag = case @k\n in Integer then 'a'\n else 'b'\n end)")).to eq(Set[])
  end

  it "counts an `||` whose right side may be nil unless its left side is a truthy literal" do
    expect(writes("def r = (@tag = @items.first || nil)")).to eq(Set[:@tag])
    expect(writes("def r = (@tag = @items.first || (@x if ready?))")).to eq(Set[:@tag])
    expect(writes("def r = (@tag = 'a' || nil)")).to eq(Set[])
    expect(writes("def r = (@tag = \"\#{@k}\" || nil)")).to eq(Set[])
    expect(writes("def r = (@tag = @items.first || 'a')")).to eq(Set[])
    expect(writes("def r = (@tag = @peer&.tag || 'a')")).to eq(Set[])
  end

  it "counts an `&&` whose left side may be nil, or whose right side may be nil past a left side that is not false" do
    expect(writes("def r = (@tag = ready? && nil)")).to eq(Set[:@tag])
    expect(writes("def r = (@tag = @peer&.tag && 'a')")).to eq(Set[:@tag])
    expect(writes("def r = (@tag = false && nil)")).to eq(Set[])
    expect(writes("def r = (@tag = ready? && 'a')")).to eq(Set[])
  end

  # Guard: both already answer so before #2482; Ruby's `&.` does not skip the rest of a chain.
  it "counts a chained safe-navigation call, and not a plain call past one, which raises on nil" do
    expect(writes("def r = (@tag = @peer&.tag&.upcase)")).to eq(Set[:@tag])
    expect(writes("def r = (@tag = @peer&.tag.upcase)")).to eq(Set[])
  end

  it "counts every target after the first against a literal Ruby does not splat, and none against a computed value" do
    expect(writes("def r = (@a, @tag = 1)")).to eq(Set[:@tag])
    expect(writes("def r = (@a, @b, @tag = 's')")).to eq(Set[:@b, :@tag])
    expect(writes("def r = (@a, @tag = { k: 1 })")).to eq(Set[:@tag])
    expect(writes("def r = (@a, @tag = nil)")).to eq(Set[:@a, :@tag])
    expect(writes("def r = (@a, @tag = @peer&.pair)")).to eq(Set[:@a, :@tag])
    expect(writes("def r = (@a, @tag = [1, 2])")).to eq(Set[])
    expect(writes("def r = (@a, @tag = @items)")).to eq(Set[])
    # Guard: pins the current answer. Ruby binds `@tag` to `nil` here, but a rest target keeps the decline.
    expect(writes("def r = (@a, @tag, *@r = 1)")).to eq(Set[])
  end

  it "judges a nested target on the same rule against its own element" do
    expect(writes("def r = ((@a, @tag), @b = [1, nil], 2)")).to eq(Set[:@tag])
    expect(writes("def r = ((@a, @tag), @b = 1, 2)")).to eq(Set[:@tag])
    expect(writes("def r = (@b, (@a, @tag) = 1)")).to eq(Set[:@a, :@tag])
    expect(writes("def r = ((@a, @tag), @b = [1, 2], 3)")).to eq(Set[])
    expect(writes("def r = ((@a, @tag), @b = pair, 3)")).to eq(Set[])
  end

  # Issue #2482 — the straight-line last-write rule: a later top-level unconditional write of a value not counted as
  # `nil` drops an earlier `nil` write, unless control may leave the method between them.
  def body_of(*lines) = "def r\n#{lines.map { |line| "    #{line}\n" }.join}  end"

  it "drops a nil write that a later top-level write of a value overwrites" do
    [["@tag = @parts.first || nil", "@tag = 'x'", "yield if block_given?"],
     ["@tag = @parts.first || nil", "@tag ||= 'default'"],
     ["@a, @tag = 1", "@tag = 'x'"],
     ["@tag = nil", "@tag = 'x'"],
     ["@a, @tag = 1, nil", "@tag = 'x'"],
     ["@tag = nil", "@tag ||= 'd'"],
     ["@tag = @peer&.tag", "@tag = 'x'"],
     ["@tag = nil", "@a, @tag = 1, 2"],
     ["@tag = nil", "(@a, @tag), @b = [1, 2], 3"],
     ["@tag = nil", "notify", "@tag = 'x'"]].each do |lines|
      expect(writes(body_of(*lines))).to eq(Set[]), lines.join("; ")
    end
    expect(writes("def r = (@tag = nil; @tag = 'x')")).to eq(Set[])
    expect(writes("def clear = (@tag = nil)\n  #{body_of('clear', "@tag = 'x'")}")).to eq(Set[])
  end

  it "keeps a nil write the later write may not reach or does not overwrite" do
    [["@tag = nil", "@tag = 'x' if ready?"],
     ["@tag = nil", "return if ready?", "@tag = 'x'"],
     ["@tag = nil", "raise 'no' if ready?", "@tag = 'x'"],
     ["@tag = nil", "yield", "@tag = 'x'"],
     ["@tag = nil", "@items.each { |i| i }", "@tag = 'x'"],
     ["@tag = nil", "[1].each { @tag = 'x' }"],
     ["@tag = nil", "@tag = @items.map { |i| i }"],
     ["@tag = nil", "@tag &&= 'x'"],
     ["@tag = 'x'", "@tag = nil"],
     ["@tag = nil", "@tag = 'x'", "rescue StandardError", "nil"]].each do |lines|
      expect(writes(body_of(*lines))).to eq(Set[:@tag]), lines.join("; ")
    end
    # Guard: pins the current answer. Ruby binds `@tag` to 2, but a rest target is no overwrite, as the census
    # declines it.
    expect(writes(body_of("@tag = nil", "@a, @tag, *@r = 1, 2"))).to eq(Set[:@tag])
  end

  it "reads a block's body but not a lambda's, a nested def's or a class body's" do
    expect(writes("def r = [1].each { @tag = nil }")).to eq(Set[:@tag])
    expect(writes("def r = (f = -> { @tag = nil }; f.arity)")).to eq(Set[])
    expect(writes("def r\n  def inner = (@tag = nil)\nend")).to eq(Set[])
  end

  it "follows the callee's own self-calls, and stops past the def budget" do
    expect(writes("def clear = (@tag = nil)\n  def r = clear")).to eq(Set[:@tag])
    expect(writes("def clear = (@tag = nil)\n  def r = self.clear")).to eq(Set[:@tag])
    chain = [*(1..8).map { |i| "def s#{i} = s#{i + 1}" }, "def s9 = (@tag = nil)"].join("\n")
    expect(writes(chain, target: "s2")).to eq(Set[:@tag])
    expect(writes(chain, target: "s1")).to eq(Set[])
  end

  it "falls back to a project module the class includes" do
    prelude = "module Resetter\n  def r = (@tag = nil)\nend"
    expect(writes("include Resetter", prelude: prelude)).to eq(Set[:@tag])
  end

  # Guard: `Scope#user_def_for` holds instance-side defs only, so the receiver check in `def_node` is a second fence.
  it "does not take a singleton def as the callee" do
    expect(writes("def self.r = (@tag = nil)")).to eq(Set[])
  end
end
