# frozen_string_literal: true

# Issue #1237 — a call-site `*splat` was carried as one argument and bound positionally when a user `def` body was
# re-typed for the call's return: `def count(*keys) = keys.size` called as `r.count(*idx)` with a two-element `idx`
# folded to `1`, and `if n == 2` reported `flow.always-truthy-condition` on a program that takes the branch. Every
# tier that re-types a body from the call's arguments now declines under a splat.
require "spec_helper"

RSpec.describe "a call-site splat does not bind as one positional argument (#1237)", type: :runner do
  def rules(source, sig: {})
    analyze(source, sig: sig).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }
  let(:row) { "class Row\n  def count(*keys) = keys.size\nend" }

  # `defs` at top level, then `call` assigned to `n` and compared with `expected`.
  def program(defs, call, expected: 2)
    <<~RUBY
      #{defs}
      idx = [0, 1]
      n = #{call}
      puts "hit" if n == #{expected}
    RUBY
  end

  it "does not fold the issue's index read" do
    defs = "class Row\n  def [](*keys) = keys.size\nend"
    expect(rules(program(defs, "Row.new[*idx]"))).to eq([])
  end

  it "does not fold an instance call" do
    expect(rules(program(row, "Row.new.count(*idx)"))).to eq([])
  end

  it "does not fold a splat after a leading positional" do
    expect(rules(program(row, "Row.new.count(1, *idx)", expected: 3))).to eq([])
  end

  it "does not fold a splat before a trailing positional" do
    expect(rules(program(row, "Row.new.count(*idx, 2)", expected: 3))).to eq([])
  end

  it "does not fold a splat of a literal array" do
    expect(rules(program(row, "Row.new.count(*[1, 2])"))).to eq([])
  end

  it "does not fold a singleton call" do
    defs = "class K\n  def self.count(*keys) = keys.size\nend"
    expect(rules(program(defs, "K.count(*idx)"))).to eq([])
  end

  it "does not fold an implicit-self call to a top-level def" do
    expect(rules(program("def count(*keys) = keys.size", "count(*idx)"))).to eq([])
  end

  it "does not fold a call through a refinement" do
    defs = "module R\n  refine Integer do\n    def count(*keys) = keys.size\n  end\nend\nusing R"
    expect(rules(program(defs, "1.count(*idx)"))).to eq([])
  end

  it "does not let the inherited declaration speak for an overriding def" do
    defs = "class Base\nend\nclass Sub < Base\n  def count(*keys) = keys.size\nend"
    sig = { "base.rbs" => "class Base\n  def count: (*untyped) -> 1\nend\n" }
    expect(rules(program(defs, "Sub.new.count(*idx)"), sig: sig)).to eq([])
  end

  describe "controls: the body still answers without a positional splat" do
    it "folds positional arguments" do
      expect(rules(program(row, "Row.new.count(0, 1)", expected: 3))).to eq(always)
    end

    it "folds a call with a block argument" do
      defs = "class Row\n  def count(*keys) = keys.size\nend\nblk = proc { 1 }"
      expect(rules(program(defs, "Row.new.count(&blk)", expected: 1))).to eq(always)
    end

    it "binds a keyword splat of a closed hash shape" do
      defs = "class Row\n  def kw(a: 1) = a\nend\nh = { a: 2 }"
      expect(rules(program(defs, "Row.new.kw(**h)", expected: 3))).to eq(always)
    end
  end
end
