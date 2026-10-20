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

  # Ruby: "y" (control).
  it "keeps typing from the aliased def with no later definer" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 5, '"y"']])
      class K
        def y = "y"
        alias x y
      end
      K.new.x.even?
    RUBY
  end
end
