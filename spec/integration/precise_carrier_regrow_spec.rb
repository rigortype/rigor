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

    it "joins a store outside a literal element and keeps one of the same literal" do
      seed = "ARGV.map(&:to_i).map { \"x\" }.to_set"
      source = "s = #{seed}\ns << \"x\"\ndump_type(s)\nt = #{seed}\nt << \"y\"\ndump_type(t)"
      expect(dumped(source)).to eq(['Set["x"]', 'Set["x" | String]'])
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

  # A literal element (`ints.map { "x" }` is `Array["x"]`) is a precise element too. Its pin used to survive every
  # store, so an `==` read of the stored value folded always-falsey on a program that prints. Ruby witnesses
  # (`ruby -e 'ints = [1]; ...'`): each `puts` below runs.
  describe "a literal element under a store" do
    def flow(source)
      errors("ints = ARGV.map(&:to_i)\n#{source}").grep(/\Aflow\./)
    end

    {
      "the String repro" => ['s = ints.map { "x" }', 's << "y"', 'puts "2" if s.last == "y"'],
      "the bool repro" => ["s = ints.map { |i| i.positive? }", "s << false", 'puts "1" if s.last == false'],
      "the fill repro" => ["s = ints.map { :keep }", "s.fill(:drop)", 'puts "3" if s.first == :drop'],
      "the concat repro" => ["s = ints.map { true }", "s.concat([false])", 'puts "7" if s.last == false']
    }.each do |label, (seed, store, read)|
      it "does not fold #{label}" do
        expect(flow("#{seed}\n#{store}\n#{read}\n")).to be_empty
      end
    end

    literals = { "a String" => ['"x"', '"y"'], "a Symbol" => %w[:keep :drop], "true" => %w[true false],
                 "an Integer" => %w[1 2], "a Float" => %w[1.5 2.5], "nil" => %w[nil 0] }
    stores = { "<<" => "s << NEW", "push" => "s.push(NEW)", "concat" => "s.concat([NEW])", "fill" => "s.fill(NEW)",
               "[]=" => "s[0] = NEW", "insert" => "s.insert(0, NEW)", "unshift" => "s.unshift(NEW)" }
    literals.each do |kind, (old, new)|
      stores.each do |name, store|
        it "does not fold a read of #{kind} element after #{name} stores another literal" do
          source = "s = ints.map { #{old} }\n#{store.sub('NEW', new)}\n" \
                   "puts 1 if s.first == #{new}\nputs 2 if s.last == #{new}\nputs 3 if s.include?(#{new})\n"
          expect(flow(source)).to be_empty
        end
      end
    end

    it "joins the stored literal's class" do
      expect(dumped("s = ARGV.map(&:to_i).map { \"x\" }\ns << \"y\"\ndump_type(s)")).to eq(['Array["x" | String]'])
    end

    # Control: a store of the literal already held changes nothing, so the correct always-truthy fold stays.
    it "keeps the carrier and its fold under a store of the same literal" do
      source = "s = ARGV.map(&:to_i).map { \"x\" }\ns << \"x\"\ndump_type(s)"
      expect(dumped(source)).to eq(['Array["x"]'])
      expect(flow("s = ints.map { \"x\" }\ns << \"x\"\nputs 1 if s.last == \"x\"\n"))
        .to eq(["flow.always-truthy-condition"])
    end
  end

  # A store the element accepts changes nothing; joining it would only add the store's shape-erased class.
  it "keeps a Tuple element a store it already covers" do
    source = "s = ARGV.map { |v| [v.size, v.size] }\ns << [2, 3]\ndump_type(s)"
    expect(dumped(source)).to eq(["Array[[non-negative-int, non-negative-int]]"])
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
