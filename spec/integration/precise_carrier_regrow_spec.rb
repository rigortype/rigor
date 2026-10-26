# frozen_string_literal: true

# Issue #2361 — a PRECISE `Array[E]` / `Set[E]` (no `Dynamic` arm in `E`, an RBS return such as `ARGV.dup` or
# `Array#to_set`) re-grows under a store of another type, joining the stored element type onto the seed.
#
# Ruby witnesses (`ruby -e 'require "set"; ...'` with no arguments):
# `f = ARGV.to_set; f.clear; f << 1; p f.map { |v| v.fdiv(2) }` prints `[0.5]`;
# `a = ARGV.dup; a.clear; a << 1; p a.map { |v| v.fdiv(2) }` prints `[0.5]`.
require "spec_helper"

RSpec.describe "Precise carrier re-grow (issue #2361)", type: :runner do
  def dumped(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\nflag = ARGV.empty?\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def errors(source, **)
    diagnostics = analyze(source, **).diagnostics
    diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  describe "the headline snippets" do
    it "reports nothing on a Set emptied and refilled with Integers" do
      expect(errors("f = ARGV.to_set; f.clear; f << 1; f.each { |v| v.fdiv(2) }\n")).to be_empty
    end

    it "reports nothing on an Array emptied and refilled with Integers" do
      expect(errors("a = ARGV.dup; a.clear; a << 1; a.each { |v| v.fdiv(2) }\n")).to be_empty
    end
  end

  describe "an Array[String] under a store" do
    {
      "<<" => ["a << 1", "Array[Integer | String]"],
      "clear then <<" => ["a.clear\na << 1", "Array[Integer | String]"],
      "<< of the element's own class" => ["a << \"x\"", "Array[String]"],
      "push with several arguments" => ["a.push(1, :x)", "Array[Integer | String | Symbol]"],
      "concat" => ["a.concat([1])", "Array[Integer | String]"],
      "unshift" => ["a.unshift(1)", "Array[Integer | String]"],
      "insert" => ["a.insert(0, 1)", "Array[Integer | String]"],
      "[]=" => ["a[0] = 1", "Array[Integer | String]"],
      "a splicing []=" => ["a[0, 0] = [1]", "Array[Integer | String]"],
      "fill" => ["a.fill(1)", "Array[Integer | String]"],
      "replace" => ["a.replace([1])", "Array[Integer | String]"],
      "a splat push" => ["xs = [1, 2]\na.push(*xs)", "Array[Dynamic[top] | String]"],
      "a store under if" => ["a << 1 if flag", "Array[Integer | String] | Array[String]"],
      "a store under unless" => ["a << 1 unless flag", "Array[Integer | String] | Array[String]"],
      "a store under case" => ["case ARGV.size\nwhen 1 then a << 1\nend", "Array[Integer | String] | Array[String]"],
      "a store in a loop body" => ["while flag\n  a << 1\nend", "Array[1 | String]"],
      "a store in a block" => ["[1].each { |i| a << i }", "Array[1 | String]"]
    }.each do |label, (body, expected)|
      it "joins the stored type after #{label}" do
        expect(dumped("a = ARGV.dup\n#{body}\ndump_type(a)")).to eq([expected])
      end
    end

    it "leaves a rewriter alone, as it did" do
      expect(dumped("a = ARGV.dup\na.map! { 1 }\ndump_type(a)")).to eq(["Array[String]"])
    end
  end

  describe "a Set[String] under a store" do
    {
      "add" => ["s.add(1)", "Set[Integer | String]"],
      "<<" => ["s << 1", "Set[Integer | String]"],
      "add?" => ["s.add?(1)", "Set[Integer | String]"],
      "merge over several enumerables" => ["s.merge([1], [:x])", "Set[Integer | String | Symbol]"],
      "replace" => ["s.replace([1])", "Set[Integer | String]"],
      "<< in a block" => ["[1].each { |i| s << i }", "Set[Dynamic[top] | String]"]
    }.each do |label, (body, expected)|
      it "joins the stored type after #{label}" do
        expect(dumped("s = ARGV.to_set\n#{body}\ndump_type(s)")).to eq([expected])
      end
    end

    it "floors a precise Set a self-call grows through a Set-only adder" do
      source = "def put(s) = s.add(1)\ns = ARGV.to_set\nput(s)\ndump_type(s)"
      expect(dumped(source)).to eq(["Set[Dynamic[top] | String]"])
    end
  end

  it "re-grows a parameter declared Array[String] in RBS locally" do
    source = <<~RUBY
      class Q
        def take(a)
          a << 1
          a.each { |v| v.fdiv(2) }
        end
      end
    RUBY
    sig = { "q.rbs" => "class Q\n  def take: (Array[String] a) -> void\nend\n" }
    expect(errors(source, sig: sig)).to be_empty
  end

  describe "receivers whose behaviour is unchanged" do
    it "keeps a Tuple's seed-admissibility floor" do
      expect(dumped("l = [1, 2]\nl << \"a\"\ndump_type(l)")).to eq(["Array[1 | 2 | Dynamic[top]]"])
    end

    it "keeps a constant Set's floor" do
      expect(dumped("l = Set[1]\nl << \"a\"\ndump_type(l)")).to eq(["Set[Dynamic[top] | Integer | String]"])
    end

    it "does not re-grow an Array subclass through its own <<" do
      source = "class MyList < Array\n  def <<(_x) = self\nend\nl = MyList.new\nl << 1\ndump_type(l)"
      expect(dumped(source)).to eq(["MyList"])
    end
  end
end
