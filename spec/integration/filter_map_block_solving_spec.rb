# frozen_string_literal: true

require "spec_helper"

# Issue #2322 — `Enumerable#filter_map: [U] () { (E) -> (nil | false | U) } -> Array[U]` spells its block return
# as the variable beside falsey arms, which the method-level binder read only as a bare variable, so `U` stayed
# free and every `filter_map` answered `Array[Dynamic[top]]`. `U` is now the block's type less `nil` and `false`
# (`RbsDispatch#compose_block_type_vars`).
RSpec.describe "filter_map block-return solving", type: :runner do
  def prelude
    %(require "set"\nrequire "rigor/testing"\ninclude Rigor::Testing\n)
  end

  # Each expression is typed inside a method whose RBS gives the receivers their types.
  def probe_sig
    {
      "probe.rbs" => "class Probe\n  def probe: (Array[Symbol] refs, Set[Integer] s, Hash[Symbol, Integer] h, " \
                     "Array[Integer] ints, bool flag, untyped u) -> void\nend\n"
    }
  end

  def dumped_type(expression)
    source = "#{prelude}class Probe\n  def probe(refs, s, h, ints, flag, u)\n    dump_type(#{expression})\n  " \
             "end\nend\n"
    dumped(source, sig: probe_sig).first
  end

  def dumped(source, sig: {})
    analyze(source, sig: sig).diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  it "solves U from a block that returns a value or nil" do
    expect(dumped_type("refs.filter_map { |r| r.to_s if r }")).to eq("Array[String]")
  end

  it "solves U from a block that returns the element itself" do
    expect(dumped_type("refs.filter_map { |r| r }")).to eq("Array[Symbol]")
  end

  it "removes false from the block's type and keeps the rest" do
    expect(dumped_type("ints.filter_map { |i| i.odd? ? false : i }")).to eq("Array[Integer]")
  end

  it "keeps true, removing only false and nil" do
    expect(dumped_type("ints.filter_map { |i| i.odd? }")).to eq("Array[true]")
    expect(dumped_type("ints.filter_map { |i| flag ? true : nil }")).to eq("Array[true]")
  end

  it "answers an Array that holds no element when the block only answers nil or false" do
    expect(dumped_type("ints.filter_map { |i| nil }")).to eq("Array[bot]")
    expect(dumped_type("ints.filter_map { |i| false }")).to eq("Array[bot]")
  end

  # Guard: the fix passes a Dynamic block type through unchanged, so no removal of it fails this.
  it "keeps the Dynamic[top] element for an untyped block" do
    expect(dumped_type("ints.filter_map { |i| u.foo }")).to eq("Array[Dynamic[top]]")
  end

  it "solves U on Set, Hash, Range and Enumerator receivers" do
    {
      "s.filter_map { |i| i.to_s if i.odd? }" => "Array[decimal-int-string]",
      "h.filter_map { |k, v| k.to_s if v > 1 }" => "Array[String]",
      "h.filter_map { |pair| pair[1] }" => "Array[Integer]",
      "(1..ints.size).filter_map { |i| i.to_s if i > 2 }" => "Array[decimal-int-string]",
      "ints.each_with_index.filter_map { |i, idx| idx.to_s if i > 1 }" => "Array[decimal-int-string]"
    }.each do |expression, expected|
      expect(dumped_type(expression)).to eq(expected), expression
    end
  end

  # Guard: the blockless overload has no block return to solve.
  it "leaves the blockless call an Enumerator" do
    expect(dumped_type("ints.filter_map")).to eq("Enumerator[Integer, Array[Dynamic[top]]]")
  end

  it "solves a symbol block-pass as map does" do
    expect(dumped_type("refs.filter_map(&:to_s)")).to eq("Array[String]")
  end

  it "reads every next value as the block's, less nil, and a break value as the call's" do
    expect(dumped_type('ints.filter_map { |i| next nil if i > 3; next "x" if i > 1; i.to_f }'))
      .to eq(%(Array["x" | Float]))
    expect(dumped_type("ints.filter_map { |i| break :stop if i > 3; i.to_s }"))
      .to eq("Array[decimal-int-string] | :stop").or eq(":stop | Array[decimal-int-string]")
  end

  # Guards: these calls never reach the RBS block binder, with or without the fix.
  it "does not apply the core solving to a project class's own filter_map" do
    source = "#{prelude}class Mine\n  def filter_map = 42\nend\ndump_type(Mine.new.filter_map { |x| x })\n"
    expect(dumped(source)).to eq(["42"])
  end

  it "does not apply the core solving to a refined filter_map" do
    source = <<~RUBY
      #{prelude}
      module R
        refine Array do
          def filter_map = :refined
        end
      end
      using R
      dump_type([1].filter_map { |x| x.to_s })
    RUBY
    expect(dumped(source)).to eq([":refined"])
  end

  it "keeps the shape-driven element of a Tuple or HashShape receiver" do
    expect(dumped_type('[1, :a, "s"].filter_map { |e| e.to_s if e }')).to eq(%(["1", "a", "s"]))
    expect(dumped_type("{ a: 1, b: 2 }.filter_map { |k, v| v.to_s }")).to eq(%(Array["1" | "2"]))
  end

  # The rule reads the declared spelling, not the method name: `U?` strips `nil` alone and keeps `false`, and an
  # arm other than `nil` / `false` (`bool`, `String`), `false` without `nil`, or a second variable leaves the
  # variable unbound.
  it "reads a U? block return and declines any other arm or a second variable" do
    sig = {
      "box.rbs" => <<~RBS
        class Box
          def pick: [U] () { () -> U? } -> Array[U]
          def with_bool: [U] () { () -> (U | bool) } -> Array[U]
          def only_false: [U] () { () -> (U | false) } -> Array[U]
          def with_other: [U] () { () -> (U | nil | String) } -> Array[U]
          def two: [U, V] () { () -> (U | V | nil) } -> Array[U]
        end
      RBS
    }
    source = <<~RUBY
      #{prelude}
      n = [1, nil].sample
      dump_type(Box.new.pick { n })
      dump_type(Box.new.with_bool { n })
      dump_type(Box.new.only_false { n })
      dump_type(Box.new.with_other { n })
      dump_type(Box.new.two { n })
      m = [false, 1, nil].sample
      dump_type(Box.new.pick { m })
    RUBY
    expect(dumped(source, sig: sig)).to eq(["Array[1]", *Array.new(4, "Array[Dynamic[top]]"), "Array[1 | false]"])
  end

  # A receiver class whose Ruby source defines `filter_map` itself is trusted to its own body, not to the core
  # signature: this one keeps `false` (`compact` drops only `nil`), so stripping it would read `Array[true]` and
  # fold `b.last == false` always-falsey on correct code.
  it "leaves U unbound for a class that defines filter_map in Ruby over an Enumerable declaration" do
    sig = {
      "coll2.rbs" => <<~RBS
        class Coll2
          include Enumerable[Integer]
          def each: () { (Integer) -> void } -> void
        end
      RBS
    }
    source = <<~RUBY
      #{prelude}
      class Coll2
        include Enumerable
        def each
          yield 1
          yield 2
        end

        def filter_map(&blk) = map(&blk).compact
      end
      dump_type(Coll2.new.filter_map { |i| i.odd? })
    RUBY
    expect(dumped(source, sig: sig)).to eq(["Array[Dynamic[top]]"])
  end

  # A filter_map result is a precise Array (`Array[true]`, `Array["x"]`), and a later `<<` / `fill` / `concat` of a value
  # outside it must re-grow the element (#2361) rather than leave the pin, or the `==` read folds always-falsey on a
  # program that prints. Ruby prints 1, 2, 3 and 7 for `ints = [1, 0, 2]`.
  it "re-grows a filter_map result that a later write widens" do
    sig = { "repro.rbs" => "class Repro\n  def run: (Array[Integer] ints) -> void\nend\n" }
    source = <<~RUBY
      class Repro
        def run(ints)
          a = ints.filter_map { |i| i.positive? }; a << false; puts 1 if a.last == false
          s = ints.filter_map { |i| "x" if i > 0 }; s << "y"; puts 2 if s.last == "y"
          t = ints.filter_map { |i| :keep if i > 0 }; t.fill(:drop); puts 3 if t.first == :drop
          b = ints.filter_map { |i| i.zero? }; b.concat([false]); puts 7 if b.last == false
        end
      end
    RUBY
    expect(analyze(source, sig: sig).diagnostics.map { |d| [d.line, d.rule.to_s] }).to eq([])
  end
end
