# frozen_string_literal: true

require "spec_helper"

# Issue #2292 — a value-position `h[k] ||= v` on an untyped receiver read the fresh rvalue's literal, though the
# slot may already hold what an earlier call stored. On an untracked receiver (a `Dynamic` / `Top` constituent)
# `StatementEvaluator#untracked_memo_value` keeps the rvalue only as far as its class is known.
RSpec.describe "index `||=` in value position (memoization idiom)", type: :runner do
  def diagnostics_for(source)
    analyze(source).diagnostics.reject { |d| d.severity.to_s == "info" }.map { |d| [d.rule, d.message] }
  end

  def dumped_type(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end.first
  end

  describe "an untyped receiver whose slot an earlier call may have filled" do
    {
      # Runtime: `h = {k: {name: "s"}}` returns "S". Guard: the stored `Dynamic[top] | {}` is silent too; the
      # erasure is pinned by the dumped-type example below.
      "a hash rvalue" => "def a(h, k) = (h[k] ||= {})[:name].upcase\n",
      # Runtime: `h = {k: ["ab"]}` returns 2. Guard, as for the hash rvalue.
      "an array rvalue" => "def b(h, k) = (h[k] ||= []).last.size\n",
      # Runtime: `h = {k: "s"}` returns "S".
      "an integer rvalue" => "def c(h, k) = (h[k] ||= 1).upcase\n",
      # Runtime: `h = {k: :b}` returns true (guard: did not reproduce on master).
      "a symbol rvalue" => "def d(h, k) = ((h[k] ||= :a) == :b) ? 1 : 2\n"
    }.each do |label, source|
      it "reports nothing for #{label}" do
        expect(diagnostics_for(source)).to eq([])
      end
    end

    it "erases a hash literal rvalue to its class" do
      expect(dumped_type("def a(h, k) = dump_type(h[k] ||= {})\n")).to eq("Hash[Dynamic[top], Dynamic[top]]")
    end

    it "unions a literal scalar rvalue with the unknown slot" do
      expect(dumped_type("def c(h, k) = dump_type(h[k] ||= 1)\n")).to eq("1 | Dynamic[top]")
    end

    it "keeps a parameterised nominal rvalue as itself" do
      # A construction keeps the #1155 reading; erased, sig-gen would propose `Array[untyped]` for a memo reader.
      expect(dumped_type("def e(h, k) = dump_type(h[k] ||= ENV.keys)\n")).to eq("Array[String]")
    end
  end

  it "RESIDUAL: still reads the literal one level below a local the #2288 local bind erased" do
    # Runtime: `h = {k: {j: "s"}}` returns "S". `x` is `Hash[untyped, untyped]`, a tracked receiver like the
    # in-place-widened `pool = {}` of a block fold, so the literal reading stays (approval-queue.d entry for #2292).
    source = "def b(h, k)\n  x = (h[k] ||= {})\n  (x[:j] ||= 1).upcase\nend\n"
    expect(diagnostics_for(source).map(&:first)).to eq(["call.undefined-method"])
  end

  it "keeps a local hash literal's precise answer (no regression)" do
    # Runtime: [1]. The slot is provably absent, so the read is not gradual and no memo reading applies.
    expect(diagnostics_for("def g\n  h = {}\n  (h[:a] ||= []).push(1)\nend\n")).to eq([])
  end

  it "reports nothing on a Hash.new(0) default slot" do
    # Runtime: 0 (the default is truthy, so the write never runs).
    expect(diagnostics_for("def i\n  h = Hash.new(0)\n  h[:z] ||= 5\nend\n")).to eq([])
  end

  it "still reports a missing method on a typed receiver's value type (control)" do
    # Runtime: NoMethodError for String.
    result = analyze("class T\n  def m(h, k) = (h[k] ||= \"d\").nosuch\nend\n",
                     sig: { "t.rbs" => "class T\n  def m: (Hash[Symbol, String], Symbol) -> untyped\nend\n" })
    expect(result.diagnostics.map(&:message)).to include(a_string_matching(/`nosuch' for .*String/))
  end
end
