# frozen_string_literal: true

require "spec_helper"

# Issue #2006 — an `alias x y` / `alias_method :x, :y` followed by a later definer of `x` in the same class: Ruby's
# later definer replaces the alias, so `x` must not be typed from `y`'s `def`. Ruby 4.0.5's value of `.x` is in each
# example's comment. An example marked "guard" passes without the fix too; "control" examples still report.
RSpec.describe "a later definer supersedes an earlier alias for typing (#2006)", type: :runner do
  def undefined(source = nil, files: {})
    analyze(source, files: files).diagnostics.select { |d| d.rule == "call.undefined-method" }
                                 .map { |d| [File.basename(d.path), d.line, d.message[/for (.*)\z/, 1]] }
  end

  # Ruby: 1 for both.
  it "types the name from a def that follows alias_method or alias" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 13, "1"], ["code.rb", 14, "1"]])
      class K
        def y = "y"
        alias_method :x, :y
        def x = 1
      end
      class L
        def y = "y"
        alias x y
        def x = 1
      end
      K.new.x.even?
      L.new.x.even?
      K.new.x.upcase
      L.new.x.upcase
    RUBY
  end

  # Ruby: 1.
  it "types the name from a def in a later reopening of the same file" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 9, "1"]])
      class K
        def y = "y"
        alias x y
      end
      class K
        def x = 1
      end
      K.new.x.even?
      K.new.x.upcase
    RUBY
  end

  # Ruby: 1. The caller in another file reads the project tables, not the defining file's own walk.
  it "types the name from the later def for a caller in another file" do
    files = { "k.rb" => "class K\n  def y = \"y\"\n  alias_method :x, :y\n  def x = 1\nend\n",
              "use.rb" => "K.new.x.even?\nK.new.x.upcase\n" }
    expect(undefined(files: files)).to eq([["use.rb", 2, "1"]])
  end

  # Ruby: 3. The `define_method` body is not typed, so neither call reports.
  it "does not type the name from the aliased def when a later define_method replaces it" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def y = "y"
        alias x y
        define_method(:x) { 3 }
      end
      K.new.x.even?
      K.new.x.upcase
    RUBY
  end

  # Ruby: "y" without X in the environment, 1 with it; neither answer is certain, so neither call reports. Guard: the
  # possible def already made the read decline.
  it "answers neither the alias nor the def under a conditional def" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def y = "y"
        alias_method :x, :y
        def x = 1 if ENV["X"]
      end
      K.new.x.even?
      K.new.x.upcase
    RUBY
  end

  # Ruby: K.new.w is "y" for both forms. An alias copies what its old name held at the alias, so a later `def x`
  # changes `x` and not the `w` copied from it.
  it "types a chained alias from what its old name held at the alias, not from a later def" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 13, '"y"'], ["code.rb", 14, '"y"']])
      class K
        def y = "y"
        alias x y
        alias w x
        def x = 1
      end
      class L
        def y = "y"
        alias_method :x, :y
        alias_method :w, :x
        def x = 1
      end
      K.new.w.even?
      L.new.w.even?
      K.new.w.upcase
      L.new.w.upcase
    RUBY
  end

  # Ruby: "s" for `old_x`, 1 for `x` — the classic alias chain that wraps a method before redefining it.
  it "types the saved name from the def it saved and the redefined name from the later def" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 6, "1"], ["code.rb", 7, '"s"']])
      class K
        def x = "s"
        alias old_x x
        def x = 1
      end
      K.new.x.upcase
      K.new.old_x.even?
      K.new.old_x.upcase
    RUBY
  end

  # Ruby: "s" for `old_x`; calling `x` raises NoMethodError after the `undef`, and returns 1 after `remove_method`
  # and a new `def`.
  it "types the saved name from the def it saved across an undef or a remove_method" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 14, '"s"']])
      class K
        def x = "s"
        alias old_x x
        undef x
      end
      class L
        def x = "s"
        alias_method :old_x, :x
        remove_method :x
        def x = 1
      end
      K.new.old_x.upcase
      L.new.old_x.upcase
      L.new.old_x.even?
    RUBY
  end

  # Ruby: "y" without X in the environment, 1 with it; the alias copies an uncertain `def`, so neither
  # call reports.
  it "does not type the saved name from a conditional def" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def x = "y"
        def x = 1 if ENV["X"]
        alias old_x x
      end
      K.new.old_x.even?
      K.new.old_x.upcase
    RUBY
  end

  # Ruby: 2 for both — the attr reader written after the alias answers. Guard: the attr reader already makes the
  # read decline.
  it "does not type the name from the aliased def when a later attr_reader replaces it" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def y = "y"
        alias x y
        attr_reader :x
        def initialize = (@x = 2)
      end
      class L
        def y = "y"
        alias x y
        def x = "s"
        attr_reader :x
        def initialize = (@x = 2)
      end
      K.new.x.upcase
      L.new.x.upcase
    RUBY
  end

  # Ruby: a String for each — the last alias copies a method this file does not define (inherited from `P`, an attr
  # reader, a `define_method`, a core method), or one whose name the pass cannot read. Each leaves `x` untyped, so
  # `.upcase` reports for none of them, where the earlier alias and `def` would type it 1.
  {
    "an inherited method" => "class K < P\n  def y = \"y\"\n  alias x y\n  def x = 1\n  alias x z\nend\n",
    "an attr reader" => "class K < P\n  attr_reader :z\n  def y = \"y\"\n  alias x y\n  def x = 1\n  alias x z\nend\n",
    "a define_method" => "class K < P\n  define_method(:z) { \"d\" }\n  def y = \"y\"\n  alias x y\n  def x = 1\n  " \
                         "alias x z\nend\n",
    "a core method, alias_method" => "class K\n  def y = 1\n  alias x y\n  def x = 1\n  alias_method :x, :to_s\nend\n",
    "a core method by alias" => "class K\n  def y = 1\n  alias x y\n  def x = 1\n  alias x inspect\nend\n",
    "a computed alias_method name" => "class K\n  def y = 1\n  alias x y\n  def x = 1\n  n = :x\n  " \
                                      "alias_method n, :to_s\nend\n",
    "a core method after a copy" => "class K\n  def y = 1\n  alias x y\n  alias x to_s\nend\n",
    "inherited, after a copy" => "class K < P\n  def y = 1\n  alias_method :x, :y\n  alias_method :x, :z\nend\n"
  }.each do |form, source|
    it "leaves the name untyped when the last alias copies #{form}" do
      expect(undefined(files: { "p.rb" => "class P\n  def z = \"p\"\nend\n", "k.rb" => source,
                                "use.rb" => "K.new.x.upcase\n" })).to eq([])
    end
  end

  # Ruby: "p" — the last alias copies `z`, which only a sibling file defines (file order is not load order).
  it "leaves the name untyped when the last alias copies a method a sibling file defines" do
    files = { "k.rb" => "class K\n  def y = 1\n  alias x y\n  def x = 1\n  alias x z\nend\n",
              "z.rb" => "class K\n  def z = \"p\"\nend\n", "use.rb" => "K.new.x.upcase\n" }
    expect(undefined(files: files)).to eq([])
  end

  # Ruby: "y" — the second alias replaces the def again (control).
  it "keeps typing from the aliased def when an alias follows the def again" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 7, '"y"']])
      class K
        def y = "y"
        alias x y
        def x = 1
        alias x y
      end
      K.new.x.even?
    RUBY
  end

  # Ruby: "y" for both (control).
  it "keeps typing from the aliased def with no later definer" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 9, '"y"'], ["code.rb", 10, '"y"']])
      class K
        def y = "y"
        alias x y
      end
      class L
        def y = "y"
        alias_method :x, :y
      end
      K.new.x.even?
      L.new.x.even?
    RUBY
  end
end
