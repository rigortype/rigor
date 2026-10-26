# frozen_string_literal: true

# Issue #2294 — a Set mutator widens the receiver's element with what it puts in, as the Array and Hash mutators do.
# A constant-folded `Set[...]` widens to the #2290 typed Set (`Set[E | Dynamic[top]]`) and joins the added elements;
# a typed Set whose element already carries the gradual arm re-grows. A PRECISE `Set[String]` (an RBS return such as
# `Array#to_set`) is left alone, as a precise `Array[String]` is.
#
# Ruby witnesses (`ruby -e 'require "set"; ...'`): `f = Set["a"]; f.clear; f << 1; f.map { |v| v.fdiv(2) }` is
# `[0.5]`; `s = Set[1]; s.merge(["a"])` holds `1` and `"a"`; `(Set[1] | ["a"]).to_a` is `[1, "a"]`.
require "spec_helper"

RSpec.describe "Set mutation widening", type: :runner do
  def dumped(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\nx = ARGV.first\nn = ARGV.size\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def errors(source)
    diagnostics = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics
    diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  describe "a constant-folded set under a mutator" do
    {
      "<<" => ["s = Set[1]\ns << x", "Set[Dynamic[top] | Integer | String]"],
      "add" => ["s = Set[1]\ns.add(x)", "Set[Dynamic[top] | Integer | String]"],
      "add?" => ["s = Set[1]\ns.add?(x)", "Set[Dynamic[top] | Integer | String]"],
      "merge" => ["s = Set[1]\ns.merge([\"a\"])", "Set[Dynamic[top] | Integer | String]"],
      "merge over several enumerables" => ["s = Set[1]\ns.merge([\"a\"], Set[:b])",
                                           "Set[Dynamic[top] | Integer | String | Symbol]"],
      "replace" => ["s = Set[1]\ns.replace([\"z\"])", "Set[Dynamic[top] | String]"],
      "map!" => ["s = Set[1]\ns.map! { |e| e.to_s }", "Set[Dynamic[top]]"],
      "clear" => ["s = Set[\"a\"]\ns.clear", "Set[Dynamic[top] | String]"],
      "delete" => ["s = Set[1, 2]\ns.delete(1)", "Set[Dynamic[top] | Integer]"]
    }.each do |label, (body, expected)|
      it "widens the element after #{label}" do
        expect(dumped("#{body}\ndump_type(s)")).to eq([expected])
      end
    end
  end

  describe "a typed set under a mutator" do
    it "joins each later store's element" do
      expected = ["Set[Dynamic[top] | Integer | String | Symbol]"]
      expect(dumped("s = Set[n]\ns << x\ns.add(:sym)\ndump_type(s)")).to eq(expected)
    end

    it "joins a Range argument's elements" do
      expected = ["Set[Dynamic[top] | Integer | String]"] * 2
      expect(dumped("s = Set[x]\ns.merge(1..3)\ndump_type(s)\nt = Set[x]\nt.merge(1..n)\ndump_type(t)")).to eq(expected)
    end

    it "joins merge's argument elements" do
      expect(dumped("s = Set[n]\ns.merge([x])\ndump_type(s)")).to eq(["Set[Dynamic[top] | Integer | String]"])
    end

    it "widens each set member of a union" do
      expected = ["Set[Dynamic[top] | Integer | String] | Set[Dynamic[top] | String | Symbol]"]
      expect(dumped("s = n > 0 ? Set[1] : Set[:a]\ns << x\ndump_type(s)")).to eq(expected)
    end

    # Positive control: the precise RBS answer is a claim the seam does not grow, as for `Array#dup` on ARGV.
    it "leaves a precise Set[String] untouched" do
      expect(dumped("s = ARGV.to_set\ns << 1\ndump_type(s)")).to eq(["Set[String]"])
    end
  end

  # The Set-only names (`merge`, `add`, ...) are not in-place mutators for every receiver: `Hash#merge` returns a new
  # Hash, so an iterator calling it on each row leaves the literal rows as they were.
  it "keeps a Hash literal's shape through Hash#merge in an iterator" do
    source = "rows = [{ name: \"a\" }, { name: \"b\" }]\nrows.each { |r| puts r.merge(id: 1) }\ndump_type(rows)"
    expect(dumped(source)).to eq(['[{ name: "a" }, { name: "b" }]'])
  end

  describe "set algebra" do
    {
      "|" => ["Set[n] | [x]", "Set[Dynamic[top] | Integer | String]"],
      "union" => ["Set[n].union([:d])", "Set[Dynamic[top] | Integer | Symbol]"],
      "+ on a precise set" => ["ARGV.to_set + [1]", "Set[Integer | String]"],
      "^" => ["ARGV.to_set ^ Set[:c]", "Set[String | Symbol]"],
      "| on a constant set" => ["Set[1] | [x]", "Set[Dynamic[top] | Integer | String]"]
    }.each do |label, (expr, expected)|
      it "unions both operands' elements under #{label}" do
        expect(dumped("dump_type(#{expr})")).to eq([expected])
      end
    end
  end

  # Each body is correct Ruby; none may report. `1.upcase` is the positive control. The read goes through `to_a.first`
  # because that is the read a constant-folded Set answers by element: `Set["a"].to_a.first.fdiv(2)` reports, where an
  # `each` block over it binds an untyped parameter.
  describe "a read after the mutation" do
    {
      "clear then << on a constant set" => "f = Set[\"a\"]\nf.clear\nf << 1\nf.to_a.first.fdiv(2)",
      "a membership test for an added value" => "c = Set[1, 2]\nc.merge([3])\nputs 1 if c.include?(3)",
      "a callee that fills it" => "def add_to(q) = q << 1.5\nu = Set[\"a\"]\nadd_to(u)\nu.to_a.first.floor",
      "a loop that fills it" => "l = Set[\"a\"]\ni = 0\nwhile i < 3\n  l.clear\n  l << i\n  i += 1\nend\n" \
                                "l.to_a.first.fdiv(2)",
      "a block that fills it" => "w = Set[\"a\"]\n[1].each { |i| w.clear; w << i }\nw.to_a.first.fdiv(2)"
    }.each do |label, body|
      it "does not report after #{label}" do
        expect(errors("1.upcase\n#{body}")).to eq(%w[call.undefined-method])
      end
    end

    it "does not report on a set ivar another method fills" do
      source = <<~RUBY
        1.upcase
        class Holder
          def initialize = @s = Set["a"]

          def reset
            @s.clear
            @s << 1
          end

          def use
            @s.to_a.first.fdiv(2)
            puts 1 if @s.include?(1)
          end
        end
      RUBY
      expect(errors(source)).to eq(%w[call.undefined-method])
    end

    # `add` is in no Array or Hash table, so the class-ivar census records it only through the Set one.
    it "does not fold a membership test on a set ivar another method adds to" do
      source = <<~RUBY
        class Holder
          def initialize = @s = Set["a"]
          def grow = @s.add(1)
          def use = (puts 1 if @s.include?(1))
        end
      RUBY
      expect(errors(source)).to eq([])
    end
  end

  # Issue #2363 — a Set held one level down, as an Array element or a Hash value, mutated in place. Ruby witnesses
  # (`ruby -e 'require "set"; ...'`): `arr = [Set["a"]]; arr.each { |e| e.add(1) }; arr.first.include?(1)` is true;
  # `h = { k: Set["a"] }; h[:k].add(1); h[:k].include?(1)` is true; after `subtract(["a"])`, `include?("a")` is false.
  describe "a set held inside a collection" do
    {
      "add through an iterator" => %(arr = [Set["a"]]\narr.each { |e| e.add(1) }\nputs 1 if arr.first.include?(1)),
      "merge through an iterator" => %(arr = [Set["a"]]\narr.each { |e| e.merge([1]) }\nputs 1 if arr.first.include?(1)),
      "subtract through an iterator" =>
        %(arr = [Set["a"]]\narr.each { |e| e.subtract(["a"]) }\nputs 1 if arr.first.include?("a")),
      "add through a nested iterator" =>
        %(nn = [[Set["a"]]]\nnn.each { |i| i.each { |s| s.add(1) } }\nputs 1 if nn.first.first.include?(1)),
      "add through a for loop" => %(arr = [Set["a"]]\nfor e in arr; e.add(1); end\nputs 1 if arr.first.include?(1)),
      "add on a hash value" => %(h = { k: Set["a"] }\nh[:k].add(1)\nputs 1 if h[:k].include?(1)),
      "merge on a string-keyed hash value" => %(h = { "k" => Set["a"] }\nh["k"].merge([1])\nputs 1 if h["k"].include?(1)),
      "subtract on a hash value" => %(h = { k: Set["a"] }\nh[:k].subtract(["a"])\nputs 1 if h[:k].include?("a"))
    }.each do |label, source|
      it "does not fold a membership test after #{label}" do
        expect(errors(source)).to eq([])
      end
    end

    it "widens only the hash value the mutation reached" do
      source = %(h = { k: Set["a"], j: Set["b"] }\nh[:k].add(1)\ndump_type(h))
      expect(dumped(source)).to eq(['{ k: Set[Dynamic[top] | Integer | String], j: Set["b"] }'])
    end

    # A `for` loop's value is its collection, whose shapes a Set mutation of an element drops as well.
    it "widens every hash value when the key is not a literal" do
      source = %(h = { k: Set["a"], j: Set["b"] }\nh[x.to_sym].add(1)\ndump_type(h))
      expected = "{ k: Set[Dynamic[top] | Integer | String], j: Set[Dynamic[top] | Integer | String] }"
      expect(dumped(source)).to eq([expected])
    end

    it "drops the nested shapes of a for loop's value after add on a set its element holds" do
      source = %(v = for e in [{ k: Set["a"] }]; e[:k].add(1); end\ndump_type(v))
      expect(dumped(source)).to eq(["Array[Hash[Symbol, Set]]"])
    end

    # The Set gate reads the collection's type: an iterator over Hash rows has no Set element for `merge` to mutate.
    it "keeps a Hash row tuple through Hash#merge when the rows hold no set" do
      expect(dumped("rows = [{ a: 1 }]\nrows.each { |r| r.merge(b: 2) }\ndump_type(rows)")).to eq(["[{ a: 1 }]"])
    end
  end
end
