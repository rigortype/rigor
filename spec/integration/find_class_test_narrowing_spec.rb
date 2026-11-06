# frozen_string_literal: true

# Issue #2719 — the find-family class-test narrowing reads only core `Array` / `Enumerable` finders. A project or
# RBS-declared `find` may return what its block never tested, so it keeps its own answer. The core rows are pinned in
# `fixtures/find_class_test_narrowing.rb`.
require "spec_helper"

RSpec.describe "a class-test block narrows only a core finder (#2719)", type: :runner do
  def diagnostics(source, sig: {})
    analyze(source, sig: sig).diagnostics.map { |d| [d.qualified_rule, d.message] }
  end

  it "narrows a core Array#find (the control that the narrowing is live)" do
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      nums = ARGV.map { |a| a.to_c.real }
      assert_type("Integer?", nums.find { |n| n.is_a?(Integer) })
    RUBY
    expect(diagnostics(source)).to eq([])
  end

  it "keeps a project-defined find's answer, and reports nothing on a call Ruby runs" do
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      class Repo
        def find = yield(1) ? [1.5, 2].sample : nil
      end
      r = Repo.new.find { |x| x.is_a?(Integer) }
      assert_type("1.5 | 2 | nil", r)
      r.to_f if r
    RUBY
    expect(diagnostics(source)).to eq([])
  end

  it "keeps an RBS-declared find's answer" do
    sig = { "repo.rbs" => "class Repo\n  def find: () { (String) -> bool } -> Numeric?\nend\n" }
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      class Repo
        def find = yield("s") ? 1.5 : nil
      end
      assert_type("Numeric?", Repo.new.find { |x| x.is_a?(Integer) })
    RUBY
    expect(diagnostics(source, sig: sig)).to eq([])
  end

  it "keeps the answer of a find only RBS declares (a gem class with no source in the project)" do
    sig = { "repo.rbs" => "class Repo\n  def initialize: () -> void\n  " \
                          "def find: () { (String) -> bool } -> Numeric?\nend\n" }
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      assert_type("Numeric?", Repo.new.find { |x| x.is_a?(Integer) })
    RUBY
    expect(diagnostics(source, sig: sig)).to eq([])
  end

  it "keeps the answer of a core finder the project redefines" do
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      class Array
        def rfind = last
      end
      nums = ARGV.map { |a| a.to_c.real }
      assert_type("Numeric?", nums.rfind { |n| n.is_a?(Integer) })
    RUBY
    expect(diagnostics(source)).to eq([])
  end

  it "keeps the answer of a finder a refinement in effect replaces" do
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      module R
        refine Array do
          def find = [2.5, 1, nil].sample
        end
      end
      using R
      xs = [1, 2.5].map(&:itself)
      r = xs.find { |n| n.is_a?(Integer) }
      assert_type("1 | 2.5 | nil", r)
      case r
      when Float then r.floor
      end
    RUBY
    expect(diagnostics(source)).to eq([])
  end

  it "keeps the answer of a finder a reopened Enumerable replaces" do
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      module Enumerable
        def find = 2.5
      end
      assert_type("Dynamic[top]?", (1..3).each.find { |n| n.is_a?(Integer) })
    RUBY
    expect(diagnostics(source)).to eq([])
  end

  it "keeps the answer when one member of a union receiver has a project finder" do
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      class Hash
        def find = first
      end
      ary = ARGV.map(&:size)
      hsh = ARGV.to_h { |a| [a, a.size] }
      assert_type("[String, Integer] | nil | non-negative-int", [ary, hsh].sample.find { |x| x.is_a?(Integer) })
    RUBY
    expect(diagnostics(source)).to eq([])
  end

  it "narrows a tuple receiver" do
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      assert_type(%q("a"?), [1, "a"].find { |x| x.is_a?(String) })
    RUBY
    expect(diagnostics(source)).to eq([])
  end
end
