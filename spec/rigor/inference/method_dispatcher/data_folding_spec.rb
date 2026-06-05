# frozen_string_literal: true

require "spec_helper"

# ADR-48 — `Data.define` value folding, exercised end-to-end through the
# full Runner pipeline (the project pre-pass that builds the class-name ->
# member-layout side-table only runs there, not under the reduced
# precision-snapshot harness).
RSpec.describe "Data.define value folding", type: :runner do
  # Returns the `describe(:short)` strings recorded by each `dump_type(...)`
  # call in source order.
  def dumped_types(source)
    result = analyze("require \"rigor/testing\"\ninclude Rigor::Testing\n#{source}")
    result.diagnostics
          .select { |d| d.message.start_with?("dump_type") }
          .map { |d| d.message.delete_prefix("dump_type: ") }
  end

  describe "the local-bound form" do
    it "folds Data.define, .new, member reads, and projections" do
      types = dumped_types(<<~RUBY)
        c = Data.define(:x, :y)
        dump_type(c)
        p = c.new(1, "two")
        dump_type(p)
        dump_type(p.x)
        dump_type(p.y)
        dump_type(p[:x])
        dump_type(p[1])
        dump_type(p[-1])
        dump_type(p.to_h)
        dump_type(p.deconstruct)
        dump_type(p.members)
      RUBY

      expect(types).to eq([
                            "Data.define(:x, :y)",
                            "Data(x: 1, y: \"two\")",
                            "1", "\"two\"", # p.x, p.y
                            "1", "\"two\"", "\"two\"", # p[:x], p[1], p[-1]
                            "{ x: 1, y: \"two\" }",
                            "[1, \"two\"]",
                            "[:x, :y]"
                          ])
    end

    it "folds keyword construction by member name" do
      expect(dumped_types(<<~RUBY)).to eq(%w[10 20])
        c = Data.define(:x, :y)
        p = c.new(x: 10, y: 20)
        dump_type(p.x)
        dump_type(p.y)
      RUBY
    end

    it "folds Data#with, overriding named members and preserving the rest" do
      expect(dumped_types(<<~RUBY)).to eq(["99", "\"two\""])
        c = Data.define(:x, :y)
        p = c.new(1, "two").with(x: 99)
        dump_type(p.x)
        dump_type(p.y)
      RUBY
    end
  end

  describe "the constant-assigned form" do
    it "folds Point.new and member reads, tagging the instance with the class" do
      expect(dumped_types(<<~RUBY)).to eq(["Point(x: 1, y: \"two\")", "1", "\"two\""])
        Point = Data.define(:x, :y)
        p = Point.new(1, "two")
        dump_type(p)
        dump_type(p.x)
        dump_type(p.y)
      RUBY
    end

    it "folds the Point[...] new alias" do
      expect(dumped_types(<<~RUBY)).to eq(["Point(x: 3, y: 4)"])
        Point = Data.define(:x, :y)
        dump_type(Point[3, 4])
      RUBY
    end
  end

  describe "the named-subclass form" do
    it "folds Coord.new and member reads through the recorded layout" do
      expect(dumped_types(<<~RUBY)).to eq(["Coord(lat: 35, lng: 139)", "35"])
        class Coord < Data.define(:lat, :lng)
        end
        c = Coord.new(35, 139)
        dump_type(c)
        dump_type(c.lat)
      RUBY
    end
  end

  describe "degradation (precision floors, never a wrong answer)" do
    it "degrades a positional arity mismatch to the class nominal" do
      expect(dumped_types(<<~RUBY)).to eq(["Point"])
        Point = Data.define(:x, :y)
        dump_type(Point.new(1))
      RUBY
    end

    it "degrades a keyword-key mismatch to the class nominal" do
      expect(dumped_types(<<~RUBY)).to eq(["Point"])
        Point = Data.define(:x, :y)
        dump_type(Point.new(x: 1, z: 2))
      RUBY
    end

    it "does not fold a Data.define carrying a block (slice-4 territory)" do
      # The block-form defers: the result is not a precise member class, so
      # `.new` does not materialise a precise instance.
      types = dumped_types(<<~RUBY)
        c = Data.define(:x) do
          def double = x * 2
        end
        dump_type(c.new(1).x)
      RUBY
      expect(types.first).not_to eq("1")
    end

    it "does not fold non-literal members" do
      types = dumped_types(<<~RUBY)
        names = [:x, :y]
        c = Data.define(*names)
        dump_type(c.new(1, 2))
      RUBY
      expect(types.first).not_to start_with("Data(")
    end
  end

  describe "false-positive safety" do
    it "does not flag a member read as an undefined method" do
      result = analyze(<<~RUBY)
        Point = Data.define(:x, :y)
        p = Point.new(1, 2)
        p.x
      RUBY
      expect(result).to be_success
      expect(result.diagnostics.map(&:message).join).not_to match(/undefined method/i)
    end

    it "resolves a non-member call through the Data nominal without mis-firing" do
      result = analyze(<<~RUBY)
        Point = Data.define(:x, :y)
        p = Point.new(1, 2)
        p.frozen?
        p.to_s
      RUBY
      expect(result).to be_success
      expect(result.diagnostics.map(&:message).join).not_to match(/undefined method/i)
    end
  end
end
