# frozen_string_literal: true

# Two call-site splat shapes user-method return inference now binds the way Ruby passes them.
#
# Issue #3157 — a `*splat` whose value is a `Tuple` is expanded into positionals, so `first(*[1, 2])` answers
# `1` rather than the #1237 no-correspondence `Dynamic[top]`. A Tuple with an element that may be a `Hash`
# is not expanded: a splatted array's last `ruby2_keywords` hash is passed as keywords.
#
# Issue #3099 — a lone `**h` whose value is an empty closed `HashShape` (`h = {}`, `**{}`) passes no argument.
# It was bound as one positional `{}`, so `count(**h)` with `def count(*keys) = keys.size` folded to `1`.
#
# The engine's `assert.type-mismatch` rule is the assertion channel: each fixture states the type Ruby's answer
# has, so an empty mismatch list means the engine answered exactly that. (`flow.always-truthy-condition` cannot
# serve: it fires for an always-false comparison too.)
require "spec_helper"

RSpec.describe "a call-site Tuple splat or empty double splat binds as Ruby passes it (#3157, #3099)",
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
      end
      def tcount(*keys) = keys.size
      h = {}
      t = [1, 2]
      idx = ARGV.map(&:to_i)
    RUBY
  end

  # The `assert.type-mismatch` messages for `assert_type(expected, call)` after the shared definitions.
  def mismatches(call, expected)
    source = "#{row}assert_type(#{expected.inspect}, #{call})\n"
    analyze(source).diagnostics.select { |d| d.rule == "assert.type-mismatch" }.map(&:message)
  end

  describe "a Tuple splat is expanded into positionals (#3157)" do
    it "a literal Tuple" do
      expect(mismatches("Row.new.first(*[1, 2])", "1")).to eq([])
    end

    it "a Tuple between positionals" do
      expect(mismatches("Row.new.count(0, *[1], 2)", "3")).to eq([])
    end

    it "a mixed Tuple" do
      expect(mismatches('Row.new.first(*[1, "a"])', "1")).to eq([])
    end

    it "a Tuple local into required parameters" do
      expect(mismatches("Row.new.pair(*t)", "2")).to eq([])
    end

    it "reads the keyword default when no element can be a Hash" do
      expect(mismatches("Row.new.kw(*[1])", "1")).to eq([])
    end
  end

  describe "controls: a splat that is not expanded keeps the no-correspondence binding" do
    it "a non-Tuple splat" do
      expect(mismatches("Row.new.first(*idx)", "Dynamic[top]")).to eq([])
    end

    it "a Tuple with an element that may be a Hash" do
      expect(mismatches("Row.new.kw(*[1, ENV.to_h])", "Dynamic[top]")).to eq([])
    end
  end

  describe "an empty closed double splat passes no argument (#3099)" do
    it "into a rest parameter" do
      expect(mismatches("Row.new.count(**h)", "0")).to eq([])
    end

    it "a literal empty hash" do
      expect(mismatches("Row.new.count(**{})", "0")).to eq([])
    end

    it "after a positional" do
      expect(mismatches("Row.new.count(1, **h)", "1")).to eq([])
    end

    it "leaves an optional parameter at its default" do
      expect(mismatches("Row.new.opt(**h)", "5")).to eq([])
    end

    it "leaves a trailing optional parameter at its default" do
      expect(mismatches("Row.new.two(1, **h)", "2")).to eq([])
    end

    it "through a top-level def" do
      expect(mismatches("tcount(**h)", "0")).to eq([])
    end

    it "after an expanded Tuple splat" do
      expect(mismatches("Row.new.count(*t, **h)", "2")).to eq([])
    end
  end

  describe "controls: a non-empty double splat is still one argument" do
    it "a non-empty closed shape into a rest parameter" do
      expect(mismatches("Row.new.count(**{ k: 2 })", "1")).to eq([])
    end
  end
end
