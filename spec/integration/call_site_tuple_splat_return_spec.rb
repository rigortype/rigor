# frozen_string_literal: true

# Two call-site splat shapes user-method return inference now binds the way Ruby passes them.
#
# Issue #3157 — a `*splat` of an array literal (`*[1, 2]`) is expanded into positionals, so `first(*[1, 2])`
# answers `1` rather than the #1237 no-correspondence `Dynamic[top]`. Only a literal operand has a syntactic
# arity: a `Tuple` read from a local or a method call may be a stale fold of an array that has since changed,
# so those keep the no-correspondence binding. An element that may be a `Hash` is not expanded either, since
# a splatted array's last `ruby2_keywords` hash is passed as keywords, and neither is a list whose trailing
# keyword hash is anything but a literal `**{}` or a non-empty closed shape.
#
# Issue #3099 — a literal `**{}` passes no argument and is dropped. A lone `**h` typed as an empty closed shape
# (`h = {}`) was bound as one positional `{}`, so `count(**h)` folded to `1`; it now binds with no positional
# correspondence, because the shape may be a stale read of a hash a callee filled.
#
# The engine's `assert.type-mismatch` rule is the assertion channel: each fixture states the type the engine
# must answer, so an empty mismatch list means it answered exactly that. (`flow.always-truthy-condition` cannot
# serve: it fires for an always-false comparison too.)
require "spec_helper"

RSpec.describe "a call-site literal splat or empty double splat binds as Ruby passes it (#3157, #3099)",
               type: :runner do
  let(:row) do
    <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      class Row
        def count(*keys) = keys.size
        def first(*xs) = xs.first
        def opt(a = 5) = a
        def two(a, b = 2) = b
        def pair(a, b) = b
        def kw(*a, k: 1) = k
        def self.sfirst(*xs) = xs.first
      end
      class Box
        def initialize(h) = @h = h
        def fill = @h[:k] = 1
      end
      def tcount(*keys) = keys.size
      def tfirst(*xs) = xs.first
      def fwd(...) = tcount(*[1], ...)
      h = {}
      t = [1, 2]
      idx = ARGV.map(&:to_i)
      o2 = ARGV.to_h { |a| [a.to_sym, 1] }
      x = ARGV
    RUBY
  end

  def mismatches_in(body)
    analyze("#{row}#{body}\n").diagnostics.select { |d| d.rule == "assert.type-mismatch" }.map(&:message)
  end

  # The `assert.type-mismatch` messages for `assert_type(expected, call)` after the shared definitions.
  def mismatches(call, expected)
    mismatches_in("assert_type(#{expected.inspect}, #{call})")
  end

  describe "a literal splat is expanded into positionals (#3157)" do
    it "a literal array" do
      expect(mismatches("Row.new.first(*[1, 2])", "1")).to eq([])
    end

    it "a literal between positionals" do
      expect(mismatches("Row.new.count(0, *[1], 2)", "3")).to eq([])
    end

    it "a literal with mixed element types" do
      expect(mismatches('Row.new.first(*[1, "a"])', "1")).to eq([])
    end

    it "reads the keyword default when no element can be a Hash" do
      expect(mismatches("Row.new.kw(*[1])", "1")).to eq([])
    end

    it "binds a written keyword beside the splat" do
      expect(mismatches("Row.new.kw(*[1], k: 2)", "2")).to eq([])
    end

    it "a singleton def" do
      expect(mismatches("Row.sfirst(*[1, 2])", "1")).to eq([])
    end

    it "a top-level def" do
      expect(mismatches("tfirst(*[1, 2])", "1")).to eq([])
    end

    it "a safe-navigation call" do
      expect(mismatches("Row.new&.first(*[1, 2])", "1")).to eq([])
    end

    it "an element whose type is a union of non-Hash types" do
      expect(mismatches('Row.new.count(*[ARGV.empty? ? 1 : "a"])', "1")).to eq([])
    end

    it "a nested array and an integer range element" do
      expect(mismatches("Row.new.count(*[[1], ARGV.size])", "2")).to eq([])
    end

    it "an element narrowed to a non-empty array" do
      expect(mismatches_in('assert_type("1", Row.new.count(*[x])) unless x.empty?')).to eq([])
    end
  end

  describe "controls: a splat that is not expanded keeps the no-correspondence binding" do
    it "a splat of a non-Tuple local" do
      expect(mismatches("Row.new.first(*idx)", "Dynamic[top]")).to eq([])
    end

    # Known limit: a local's Tuple may be a stale fold, so even a Tuple local is not expanded.
    it "a splat of a Tuple local" do
      expect(mismatches("Row.new.pair(*t)", "Dynamic[top]")).to eq([])
    end

    it "a splat of a method call the engine folds to a Tuple" do
      expect(mismatches("Row.new.count(*[x].reject(&:nil?))", "non-negative-int")).to eq([])
    end

    it "an element that may be a Hash" do
      expect(mismatches("Row.new.kw(*[1, ENV.to_h])", "Dynamic[top]")).to eq([])
    end

    it "an element whose union holds a Hash" do
      expect(mismatches("Row.new.kw(*[1, ARGV.empty? ? 1 : ENV.to_h])", "Dynamic[top]")).to eq([])
    end

    it "a double splat of an open hash beside the splat" do
      expect(mismatches("Row.new.count(*[1, 2], **o2)", "non-negative-int")).to eq([])
    end

    it "a mixed keyword hash beside the splat" do
      expect(mismatches("Row.new.kw(*[1], k: 2, **o2)", "Dynamic[top]")).to eq([])
    end

    it "an empty non-literal double splat beside the splat" do
      expect(mismatches("Row.new.count(*[1, 2], **h)", "non-negative-int")).to eq([])
    end

    it "a literal holding a splat of its own" do
      body = "t1 = [1]\n[2].each { t1 << _1 }\nassert_type(\"non-negative-int\", Row.new.count(*[*t1]))"
      expect(mismatches_in(body)).to eq([])
    end

    it "a splat beside a ... forwarding" do
      expect(mismatches("fwd(2, 3)", "non-negative-int")).to eq([])
    end
  end

  describe "a literal empty double splat passes no argument (#3099)" do
    it "into a rest parameter" do
      expect(mismatches("Row.new.count(**{})", "0")).to eq([])
    end

    it "after a positional" do
      expect(mismatches("Row.new.count(1, **{})", "1")).to eq([])
    end

    it "leaves an optional parameter at its default" do
      expect(mismatches("Row.new.opt(**{})", "5")).to eq([])
    end

    it "leaves a trailing optional parameter at its default" do
      expect(mismatches("Row.new.two(1, **{})", "2")).to eq([])
    end

    it "through a top-level def" do
      expect(mismatches("tcount(**{})", "0")).to eq([])
    end

    it "two of them" do
      expect(mismatches("Row.new.count(**{}, **{})", "0")).to eq([])
    end

    it "after an expanded literal splat" do
      expect(mismatches("Row.new.count(*[1, 2], **{})", "2")).to eq([])
    end
  end

  describe "an empty double splat of a local binds with no positional correspondence (#3099)" do
    it "into a rest parameter" do
      expect(mismatches("Row.new.count(**h)", "non-negative-int")).to eq([])
    end

    it "after a positional" do
      expect(mismatches("Row.new.count(1, **h)", "non-negative-int")).to eq([])
    end

    it "into an optional parameter" do
      expect(mismatches("Row.new.opt(**h)", "Dynamic[top]")).to eq([])
    end

    it "into a trailing optional parameter" do
      expect(mismatches("Row.new.two(1, **h)", "Dynamic[top]")).to eq([])
    end

    it "through a top-level def" do
      expect(mismatches("tcount(**h)", "non-negative-int")).to eq([])
    end

    # Ruby answers 1 here: `fill` stores a key into the hash `h1` names, which the local's `{}` does not see.
    it "a hash a callee filled" do
      expect(mismatches_in("h1 = {}\nBox.new(h1).fill\nassert_type(\"non-negative-int\", Row.new.count(**h1))"))
        .to eq([])
    end

    it "does not report the issue's comparison" do
      source = "#{row}a = Row.new.count(**h)\nputs \"zero\" if a == 0\n"
      expect(analyze(source).diagnostics.map(&:qualified_rule)).not_to include("flow.always-truthy-condition")
    end
  end

  describe "controls: a non-empty double splat is still one argument" do
    it "a keyword whose value is an empty literal hash" do
      expect(mismatches("Row.new.count(k: {})", "1")).to eq([])
    end

    it "a non-empty closed shape into a rest parameter" do
      expect(mismatches("Row.new.count(**{ k: 2 })", "1")).to eq([])
    end
  end
end
