# frozen_string_literal: true

# Issue #2427 — an element rewriter (`map!`, `collect!`, `flatten!`) on a precise `Array[E]` replaces `E` with the
# element its non-bang counterpart answers for the same block and arguments, and with the gradual arm where it cannot
# be typed. Keeping the stale `E` reported a missing method on the next element read.
#
# Ruby witnesses (`ruby -e '...' 4 5`):
# `a = ARGV.dup; a.map!(&:to_i); p a.first.fdiv(2)` prints `2.0`;
# `a = ARGV.map { |x| [x] }; a.flatten!; p a.first.upcase` prints `"4"`;
# `a = ARGV.dup; a.map!.with_index { |_s, i| i }; p a.first.fdiv(2)` prints `0.0`.
require "spec_helper"

RSpec.describe "Element rewriters on a precise Array (issue #2427)", type: :runner do
  def dumped(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def errors(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:message)
  end

  {
    "map! with a symbol block" => "a.map!(&:to_i)",
    "map! with a block" => "a.map! { |s| s.to_i }",
    "collect! with a symbol block" => "a.collect!(&:to_i)"
  }.each do |label, call|
    it "types the element after #{label}" do
      expect(dumped("a = ARGV.dup\n#{call}\ndump_type(a)")).to eq(["Array[Integer]"])
      expect(errors("a = ARGV.dup\n#{call}\na.first.fdiv(2)\n")).to be_empty
    end
  end

  it "keeps a precise element the rewrite preserves, and its true positive" do
    expect(dumped("a = ARGV.dup\na.map!(&:strip)\ndump_type(a)")).to eq(["Array[String]"])
    expect(errors("a = ARGV.dup\na.map!(&:strip)\na.first.fdiv(2)\n"))
      .to eq(["undefined method `fdiv' for String"])
  end

  it "takes the gradual arm for the enumerator form" do
    expect(errors("a = ARGV.dup\na.map!.with_index { |_s, i| i }\na.first.fdiv(2)\n")).to be_empty
  end

  it "keeps the non-empty witness under map!" do
    expect(dumped("a = ARGV.dup\nreturn if a.empty?\na.map!(&:to_i)\ndump_type(a)"))
      .to eq(["non-empty-array[Integer]"])
  end

  it "types the element after flatten!, dropping the non-empty witness" do
    expect(dumped("a = ARGV.map { |x| [x] }\na.flatten!\ndump_type(a)")).to eq(["Array[String]"])
    expect(errors("a = ARGV.map { |x| [x] }\na.flatten!\na.first.upcase\n")).to be_empty
    expect(errors("a = ARGV.map { |x| [x] }\na.flatten!\na.first.fdiv(2)\n"))
      .to eq(["undefined method `fdiv' for String"])
    expect(dumped("a = ARGV.map { |x| [x] }\nreturn if a.empty?\na.flatten!\ndump_type(a)"))
      .to eq(["Array[String]"])
  end

  it "flattens a Tuple element in the non-bang flatten" do
    expect(errors("ARGV.map { |x| [x] }.flatten.first.upcase\n")).to be_empty
  end

  it "reports no nil receiver on a flattened String#scan" do
    expect(errors(%(File.read("x").scan(/^path = (.+)$/).flatten.map { |path| path.strip }\n))).to be_empty
  end

  it "types a precise Set's element after map!" do
    expect(dumped(%(require "set"\ns = ARGV.to_set\ns.map!(&:to_i)\ndump_type(s)))).to eq(["Set[Integer]"])
  end

  # `Set#flatten!` flattens only nested Sets: `["4"].map { |x| [x] }.to_set.flatten!` is still `Set[["4"]]`.
  it "keeps a precise Set's element under flatten!" do
    expect(dumped(%(s = ARGV.map { |x| [x] }.to_set\ns.flatten!\ndump_type(s)))).to eq(["Set[[String]]"])
  end

  # Ruby rewrites only the binding the branch selects, so neither candidate takes the typed element.
  describe "a receiver that may name more than one binding" do
    it "gives an unselected local no rewritten element" do
      expect(errors(<<~RUBY)).to be_empty
        c = ARGV.empty?
        a = ARGV.dup
        b = ARGV.dup
        (c ? a : b).map!(&:to_i)
        b.first.upcase if c && b.first
      RUBY
    end

    it "gives an unselected ivar no rewritten element" do
      expect(errors(<<~RUBY)).to be_empty
        class Holder
          def run(c)
            @a = ARGV.dup
            @b = ARGV.dup
            (c ? @a : @b).collect! { |s| s.size }
            @b.first.upcase if c && @b.first
          end
        end
      RUBY
    end

    it "gives an unselected local no flattened element" do
      expect(errors(<<~RUBY)).to be_empty
        f = ARGV.empty?
        a = ARGV.map { |x| [x] }
        b = ARGV.map { |x| [x] }
        (f ? a : b).flatten!
        b.first.first.upcase if f && b.first
      RUBY
    end
  end
end
