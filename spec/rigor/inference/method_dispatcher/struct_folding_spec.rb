# frozen_string_literal: true

require "spec_helper"

# ADR-48 Struct follow-up — `Struct.new` value folding, exercised end-to-end
# through the full Runner pipeline (the project pre-pass that builds the
# class-name -> member-layout side-table only runs there). The distinguishing
# property versus the immutable `Data` sibling: a `Struct` is mutable, so a
# member read folds only off a FRESH (chained) instance; a read off a STORED
# binding soundly degrades to `Dynamic[top]`.
RSpec.describe "Struct.new value folding", type: :runner do
  # Returns the `describe(:short)` strings recorded by each `dump_type(...)`
  # call in source order.
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

  describe "mutation soundness (the fresh-receiver gate)" do
    it "does NOT fold a member read off a stored binding" do
      # A `Struct` is mutable, so the construction-time value is not soundly
      # foldable through a variable — it degrades to Dynamic, never a stale 1.
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        c = Struct.new(:x)
        p = c.new(1)
        dump_type(p.x)
      RUBY
    end

    it "models a member setter as returning the assigned value" do
      expect(dumped_types(<<~RUBY)).to eq(["5"])
        c = Struct.new(:x)
        p = c.new(1)
        dump_type(p.x = 5)
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
