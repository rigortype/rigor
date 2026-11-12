# frozen_string_literal: true

# Issue #1237 — a call-site `*splat` was carried as one argument and bound positionally when a user `def` body was
# re-typed for the call's return: `def count(*keys) = keys.size` called as `r.count(*idx)` with a two-element `idx`
# folded to `1`, and `if n == 2` reported `flow.always-truthy-condition` on a program that takes the branch. Every
# tier that re-types a body from the call's arguments now re-types it with no positional correspondence under a
# splat: each positional parameter is `Dynamic[top]` and the rest parameter `Array[untyped]`. The body still
# answers, so a callee that always raises keeps its `bot` and an argument-independent return is kept.
require "spec_helper"

RSpec.describe "a call-site splat does not bind as one positional argument (#1237)", type: :runner do
  def rules(source, sig: {})
    analyze(source, sig: sig).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }
  let(:row) { "class Row\n  def count(*keys) = keys.size\nend" }
  let(:overriding_sig) { { "base.rbs" => "class Base\n  def count: (*untyped) -> 1\nend\nclass Sub < Base\nend\n" } }

  # `defs` at top level, then `call` assigned to `n` and compared with `expected`.
  def program(defs, call, expected: 2)
    <<~RUBY
      #{defs}
      idx = [0, 1]
      n = #{call}
      puts "hit" if n == #{expected}
    RUBY
  end

  # `defs` at top level, then a method that calls `call` (a callee that always raises) when `x` is nil and reads
  # `x` afterwards. Correct code: the read runs only when `x` is a String.
  def raising(defs, call)
    <<~RUBY
      #{defs}
      class Caller
        def run(msgs)
          x = ENV["X"]
          #{call} if x.nil?
          x.upcase
        end
      end
    RUBY
  end

  describe "a body that reads its arguments does not fold" do
    it "the issue's index read" do
      defs = "class Row\n  def [](*keys) = keys.size\nend"
      expect(rules(program(defs, "Row.new[*idx]"))).to eq([])
    end

    it "an instance call" do
      expect(rules(program(row, "Row.new.count(*idx)"))).to eq([])
    end

    it "a splat after a leading positional" do
      expect(rules(program(row, "Row.new.count(1, *idx)", expected: 3))).to eq([])
    end

    it "a splat before a trailing positional" do
      expect(rules(program(row, "Row.new.count(*idx, 2)", expected: 3))).to eq([])
    end

    it "a splat of a literal array" do
      expect(rules(program(row, "Row.new.count(*[1, 2])"))).to eq([])
    end

    it "a singleton call" do
      defs = "class K\n  def self.count(*keys) = keys.size\nend"
      expect(rules(program(defs, "K.count(*idx)"))).to eq([])
    end

    it "an implicit-self call to a top-level def" do
      expect(rules(program("def count(*keys) = keys.size", "count(*idx)"))).to eq([])
    end

    it "a singleton method on a constant's object" do
      defs = "OBJ = Object.new\nclass << OBJ\n  def count(*keys) = keys.size\nend"
      expect(rules(program(defs, "OBJ.count(*idx)"))).to eq([])
    end

    it "a call through a refinement" do
      defs = "module R\n  refine Integer do\n    def count(*keys) = keys.size\n  end\nend\nusing R"
      expect(rules(program(defs, "1.count(*idx)"))).to eq([])
    end

    it "a ... forwarding wrapper called with a splat" do
      defs = "def count(*keys) = keys.size
def fwd(...) = count(...)"
      expect(rules(program(defs, "fwd(*idx)"))).to eq([])
    end

    it "an overriding def, and the inherited declaration does not speak for it" do
      defs = "class Base\nend\nclass Sub < Base\n  def count(*keys) = keys.size\nend"
      expect(rules(program(defs, "Sub.new.count(*idx)"), sig: overriding_sig)).to eq([])
    end
  end

  describe "a callee that always raises keeps its bot" do
    it "through an implicit-self call" do
      source = raising("", "die(*msgs)")
               .sub("class Caller\n", "class Caller\n  def die(*m) = raise(ArgumentError, m.join)\n")
      expect(rules(source)).to eq([])
    end

    it "through an explicit self call with a leading positional" do
      source = raising("", 'self.die("x", *msgs)')
               .sub("class Caller\n", "class Caller\n  def die(*m) = raise(ArgumentError, m.join)\n")
      expect(rules(source)).to eq([])
    end

    it "through a singleton def" do
      defs = "class K\n  def self.sdie(*m) = raise(ArgumentError, m.join)\nend"
      expect(rules(raising(defs, "K.sdie(*msgs)"))).to eq([])
    end

    it "through a singleton method on a constant's object" do
      defs = "OBJ = Object.new\nclass << OBJ\n  def die(*m) = raise(ArgumentError, m.join)\nend"
      expect(rules(raising(defs, "OBJ.die(*msgs)"))).to eq([])
    end

    it "through a module_function" do
      defs = "module Util\n  module_function\n\n  def bail(*m) = exit(1)\nend"
      expect(rules(raising(defs, "Util.bail(*msgs)"))).to eq([])
    end

    it "through a top-level def" do
      expect(rules(raising("def tdie(*m) = abort(m.join)", "tdie(*msgs)"))).to eq([])
    end

    it "through an overriding def" do
      defs = "class Base\nend\nclass Sub < Base\n  def count(*m) = raise(ArgumentError, m.join)\nend"
      expect(rules(raising(defs, "Sub.new.count(*msgs)"), sig: overriding_sig)).to eq([])
    end

    it "through a refinement" do
      defs = "module R\n  refine Integer do\n    def die(*m) = raise(ArgumentError, m.join)\n  end\nend\nusing R"
      expect(rules(raising(defs, "1.die(*msgs)"))).to eq([])
    end

    it "through a def with trailing positionals" do
      expect(rules(raising("def pdie(a, *r, z) = raise(ArgumentError)", "pdie(*msgs)"))).to eq([])
    end

    it "through an index read" do
      defs = "class Row\n  def [](*k) = raise(KeyError)\nend"
      expect(rules(raising(defs, "Row.new[*msgs]"))).to eq([])
    end
  end

  # An ancestry no table can order (an `include` of a module nothing defines) leaves the definer unknown, and the
  # call answers `bot` only when every project definer raises.
  describe "a callee whose definer is unknown" do
    let(:base) { "class Base\n  def fail_with(*m) = %s\nend\nclass Caller < Base\n  include Missing::Helper\nend" }

    def unknown_definer(body)
      raising(format(base, body), "fail_with(*msgs)").sub("class Caller\n", "class Caller < Base\n")
    end

    it "keeps the bot of a definer that always raises" do
      expect(rules(unknown_definer("raise(ArgumentError, m.join)"))).to eq([])
    end

    it "does not take the bot of a definer that raises for one argument only" do
      expect(rules(unknown_definer("m.size == 1 ? raise(ArgumentError) : nil")))
        .to eq(["call.possible-nil-receiver"])
    end
  end

  describe "a return that does not depend on the positionals still folds" do
    it "an argument-independent return" do
      expect(rules(program("def ok(*) = :ok", "ok(*idx)", expected: ":ok"))).to eq(always)
    end

    it "binds the rest parameter as an Array, whose size is never negative" do
      expect(rules(program(row, "Row.new.count(*idx)", expected: -1))).to eq(always)
    end

    it "a keyword the call writes beside the splat" do
      defs = "class Row\n  def kw(*a, k: 1) = k\nend"
      expect(rules(program(defs, "Row.new.kw(*idx, k: 2)", expected: 3))).to eq(always)
    end
  end

  # A splat call keyed only by its keyword shape would read the same memo key as a positional call that passes that
  # shape alone, and serve that call's answer: here `a` is empty, so `a.size` is `0`.
  it "does not share a return-memo entry with a positional call of the same keyword shape" do
    defs = "class Row\n  def kw(*a, k: 1) = a.size\nend\nRow.new.kw(k: 2)"
    expect(rules(program(defs, "Row.new.kw(*idx, k: 2)"))).to eq([])
  end

  describe "an optional parameter's default is not read" do
    it "does not take the bot of a body that raises only for the default" do
      source = raising("def maybe6(a = 1) = a == 1 ? raise(ArgumentError) : nil", "maybe6(*msgs)")
      expect(rules(source)).to eq(["call.possible-nil-receiver"])
    end

    it "does not fold to the default" do
      expect(rules(program("def opt(a = 5) = a", "opt(*[7])", expected: 7))).to eq([])
    end
  end

  describe "a splatted array may carry the keywords" do
    # `ruby2_keywords` passes a splatted array's last Hash as keywords, so with no keyword argument written the
    # keyword parameter is not read from its default.
    it "does not read the keyword default" do
      defs = "class Row\n  def kw(*a, k: 1) = k\nend"
      expect(rules(program(defs, "Row.new.kw(*idx)", expected: 1))).to eq([])
    end
  end

  describe "controls: the body still answers without a positional splat" do
    it "folds positional arguments" do
      expect(rules(program(row, "Row.new.count(0, 1)", expected: 3))).to eq(always)
    end

    it "folds a call with a block argument" do
      defs = "class Row\n  def count(*keys) = keys.size\nend\nblk = proc { 1 }"
      expect(rules(program(defs, "Row.new.count(&blk)", expected: 1))).to eq(always)
    end

    # Only a NON-EMPTY closed shape binds by name. An empty `**h` is still carried as one positional `{}` (a
    # separate, pre-existing gap filed by the #3097 review), which this change does not touch.
    it "binds a keyword splat of a non-empty closed hash shape" do
      defs = "class Row\n  def kw(a: 1) = a\nend\nh = { a: 2 }"
      expect(rules(program(defs, "Row.new.kw(**h)", expected: 3))).to eq(always)
    end
  end
end
