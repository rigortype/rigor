# frozen_string_literal: true

require "spec_helper"

# ADR-48 Struct follow-up — `Struct.new` value folding, exercised end-to-end through the full Runner pipeline (the
# project pre-pass that builds the class-name -> member-layout side-table only runs there). The distinguishing property
# versus the immutable `Data` sibling: a `Struct` is mutable, so a member read folds only off a FRESH (chained)
# instance; a read off a STORED binding soundly degrades to `Dynamic[top]`.
RSpec.describe "Struct.new value folding", type: :runner do
  # Returns the `describe(:short)` strings recorded by each `dump_type(...)` call in source order.
  def dumped_types(source)
    result = analyze("require \"rigor/testing\"\ninclude Rigor::Testing\n#{source}")
    result.diagnostics
          .select { |d| d.message.start_with?("dump_type") }
          .map { |d| d.message.delete_prefix("dump_type: ") }
  end

  describe "the class object and fresh-chain folding" do
    it "folds Struct.new, .members, .new, fresh member reads, and projections" do
      types = dumped_types(<<~RUBY)
        c = Struct.new(:x, :y)
        dump_type(c)
        dump_type(c.members)
        dump_type(c.new(1, "two"))
        dump_type(c.new(1, "two").x)
        dump_type(c.new(1, "two").y)
        dump_type(c.new(1, "two")[:x])
        dump_type(c.new(1, "two")[1])
        dump_type(c.new(1, "two").to_h)
        dump_type(c.new(1, "two").deconstruct)
      RUBY

      expect(types).to eq([
                            "Struct.new(:x, :y)",
                            "[:x, :y]",
                            "Struct(x: 1, y: \"two\")",
                            "1", "\"two\"",  # fresh .x, .y
                            "1", "\"two\"",  # fresh [:x], [1]
                            "{ x: 1, y: \"two\" }",
                            "[1, \"two\"]"
                          ])
    end

    it "defaults omitted trailing members to nil" do
      expect(dumped_types(<<~RUBY)).to eq(%w[1 nil])
        c = Struct.new(:a, :b)
        dump_type(c.new(1).a)
        dump_type(c.new(1).b)
      RUBY
    end

    it "folds Struct#with off a fresh instance" do
      expect(dumped_types(<<~RUBY)).to eq(["99", "\"two\""])
        c = Struct.new(:x, :y)
        dump_type(c.new(1, "two").with(x: 99).x)
        dump_type(c.new(1, "two").with(x: 99).y)
      RUBY
    end
  end

  describe "mutation soundness" do
    it "models a member setter as returning the assigned value" do
      expect(dumped_types(<<~RUBY)).to eq(["5"])
        c = Struct.new(:x)
        p = c.new(1)
        dump_type(p.x = 5)
      RUBY
    end

    it "does NOT fold a member read off an unrecognised local-class binding" do
      # `p = c.new(1)` where `c` is a local StructClass is conservatively not treated as a fold-safe materialisation
      # (the scan resolves the constant and inline forms, not a local-class intermediate) — degrades, never a stale
      # value.
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        c = Struct.new(:x)
        p = c.new(1)
        dump_type(p.x)
      RUBY
    end
  end

  describe "fold-safe bound locals (slice 3)" do
    it "folds a member read off a never-mutated bound local" do
      expect(dumped_types(<<~RUBY)).to eq(["1", "\"two\""])
        Point = Struct.new(:x, :y)
        p = Point.new(1, "two")
        dump_type(p.x)
        dump_type(p.y)
      RUBY
    end

    it "folds a never-mutated bound local materialised inline" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        p = Struct.new(:x).new(1)
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a bound local that escapes through an alias" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        q = p
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a bound local that escapes as a call argument" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        sink(p)
        dump_type(p.x)
      RUBY
    end

    it "folds a fold-safe bound local inside a method body" do
      expect(dumped_types(<<~RUBY)).to eq(["1"])
        Point = Struct.new(:x, :y)
        def reader
          p = Point.new(1, 2)
          dump_type(p.x)
        end
      RUBY
    end
  end

  describe "precise mutated-member re-typing (slice 4)" do
    it "re-types a member read to the assigned value after a straight-line setter" do
      expect(dumped_types(<<~RUBY)).to eq(%w[5 2])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        p.x = 5
        dump_type(p.x)
        dump_type(p.y)
      RUBY
    end

    it "reflects an incompatible-type mutation soundly (String into an Integer member)" do
      expect(dumped_types(<<~RUBY)).to eq(["\"hi\""])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        p.x = "hi"
        dump_type(p.x)
      RUBY
    end

    it "threads several straight-line setters (last write wins)" do
      expect(dumped_types(<<~RUBY)).to eq(["6"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        p.x = 5
        p.x = 6
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a member setter inside a loop (iteration-specific)" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        while cond
          p.x = p.x + 1
        end
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a member setter inside a block" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        [1].each { p.x = 9 }
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a member read after a mutation through an alias" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        q = p
        q.x = 5
        dump_type(p.x)
      RUBY
    end

    it "does NOT fold a member read after the local escapes to a callee" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        mutate!(p)
        dump_type(p.x)
      RUBY
    end
  end

  describe "the constant-assigned form" do
    it "folds a fresh member read off the constant, tagging the instance" do
      expect(dumped_types(<<~RUBY)).to eq(["Point(x: 1, y: \"two\")", "1"])
        Point = Struct.new(:x, :y)
        dump_type(Point.new(1, "two"))
        dump_type(Point.new(1, "two").x)
      RUBY
    end

    it "folds the Point[...] new alias" do
      expect(dumped_types(<<~RUBY)).to eq(["3"])
        Point = Struct.new(:x, :y)
        dump_type(Point[3, 4].x)
      RUBY
    end

    it "keeps the member layout visible inside a method body" do
      expect(dumped_types(<<~RUBY)).to eq(["3"])
        Point = Struct.new(:x, :y)
        def reader
          dump_type(Point.new(3, 4).x)
        end
      RUBY
    end
  end

  describe "the named-subclass form" do
    it "folds a fresh member read through the recorded layout" do
      expect(dumped_types(<<~RUBY)).to eq(["Coord(lat: 35, lng: 139)", "35"])
        class Coord < Struct.new(:lat, :lng)
        end
        dump_type(Coord.new(35, 139))
        dump_type(Coord.new(35, 139).lat)
      RUBY
    end
  end

  describe "keyword_init" do
    it "folds keyword construction by member name" do
      expect(dumped_types(<<~RUBY)).to eq(%w[10 20])
        KP = Struct.new(:x, :y, keyword_init: true)
        dump_type(KP.new(x: 10, y: 20).x)
        dump_type(KP.new(x: 10, y: 20).y)
      RUBY
    end

    it "degrades a positional call on a keyword_init struct (wrong form)" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        KP = Struct.new(:x, :y, keyword_init: true)
        dump_type(KP.new(1, 2).x)
      RUBY
    end
  end

  describe "degradation (precision floors, never a wrong answer)" do
    it "degrades a positional arity overflow to Dynamic" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        c = Struct.new(:x)
        dump_type(c.new(1, 2).x)
      RUBY
    end

    it "does not fold non-literal members" do
      types = dumped_types(<<~RUBY)
        names = [:x, :y]
        c = Struct.new(*names)
        dump_type(c.new(1, 2).x)
      RUBY
      expect(types.first).not_to eq("1")
    end
  end

  # Issue #293. A member holds a REFERENCE to the container the constructor was handed, so an empty literal's
  # emptiness is a fact about that argument at construction time, not about the member: "construct empty, then
  # fill" is the dominant idiom, and the pin is the only member fact whose reads fold to `nil` — the receiver
  # type that fires `call.undefined-method` on correct code. Both directions are pinned here: the empty literal
  # widens, everything else keeps folding exactly as before.
  describe "empty-container members (issue #293)" do
    it "widens an empty Array / Hash literal member to its bare nominal" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]", "Hash[Dynamic[top], Dynamic[top]]"])
        Result = Struct.new(:items, :opts)
        dump_type(Result.new([], {}).items)
        dump_type(Result.new([], {}).opts)
      RUBY
    end

    it "keeps a NON-empty container member folding precisely" do
      expect(dumped_types(<<~RUBY)).to eq(["[1, 2]", "1", "{ a: 1 }"])
        Result = Struct.new(:items, :opts)
        dump_type(Result.new([1, 2], { a: 1 }).items)
        dump_type(Result.new([1, 2], { a: 1 }).items.first)
        dump_type(Result.new([1, 2], { a: 1 }).opts)
      RUBY
    end

    it "leaves every non-container member untouched" do
      expect(dumped_types(<<~RUBY)).to eq(["1", "\"two\"", "nil"])
        Result = Struct.new(:x, :y, :z)
        dump_type(Result.new(1, "two").x)
        dump_type(Result.new(1, "two").y)
        dump_type(Result.new(1, "two").z)
      RUBY
    end

    it "widens an empty literal assigned through a member setter" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]"])
        Result = Struct.new(:items)
        r = Result.new([1])
        r.items = []
        dump_type(r.items)
      RUBY
    end

    it "widens an empty literal introduced by #with" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]", "[1]"])
        Result = Struct.new(:items, :other)
        dump_type(Result.new([1], [2]).with(items: []).items)
        dump_type(Result.new([1], [2]).with(other: []).items)
      RUBY
    end

    # The issue's repro, single-file: the member is filled by `<<` right after construction and read through the
    # factory's return, so a surviving empty-literal pin folds `.first` to `nil` and fires on correct code.
    it "stays silent on a member filled after construction" do
      result = analyze(<<~RUBY)
        module Pkg
          class Parser
            Result = Struct.new(:items, :errors)
            def self.parse(text)
              r = Result.new([], [])
              text.split(",").each { |t| r.items << Item.new(t) }
              r
            end
          end
          class Item
            def initialize(name) = @name = name
            def local = @name
          end
        end

        Pkg::Parser.parse("a,b").items.first.local
      RUBY
      expect(result.diagnostics.map(&:message).join("\n")).not_to match(/undefined method/i)
    end

    # The must-still-succeed control for the example above: the same chain over a NON-empty member still folds to
    # a real element type, so a genuine typo on it is still reported. Without this the silence above could come
    # from the whole chain having degraded rather than from the widening.
    it "still reports a genuine typo reached through a non-empty member" do
      result = analyze(<<~RUBY)
        Pair = Struct.new(:label, :items)
        def build = Pair.new("hi", [1, 2])
        build.items.first.zzz_undefined
      RUBY
      expect(result.diagnostics.map(&:message).join("\n")).to include("zzz_undefined")
    end
  end

  describe "false-positive safety" do
    it "does not flag a member read as an undefined method" do
      result = analyze(<<~RUBY)
        Point = Struct.new(:x, :y)
        p = Point.new(1, 2)
        p.x
      RUBY
      expect(result).to be_success
      expect(result.diagnostics.map(&:message).join).not_to match(/undefined method/i)
    end

    it "resolves a non-member call through the Struct nominal without mis-firing" do
      result = analyze(<<~RUBY)
        c = Struct.new(:x, :y)
        dump_type(c.new(1, 2).frozen?)
        dump_type(c.new(1, 2).to_s)
      RUBY
      expect(result).to be_success
      expect(result.diagnostics.map(&:message).join).not_to match(/undefined method/i)
    end
  end
end
