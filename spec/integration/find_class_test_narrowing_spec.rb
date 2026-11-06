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
        def find = yield(1) ? 1.5 : nil
      end
      r = Repo.new.find { |x| x.is_a?(Integer) }
      assert_type("1.5?", r)
      r.nan? if r
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
      assert_type("Numeric?", Repo.new.find { |x| x.is_a?(String) })
    RUBY
    expect(diagnostics(source, sig: sig)).to eq([])
  end
end
