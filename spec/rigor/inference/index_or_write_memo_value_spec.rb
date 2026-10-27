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
      # Runtime: `h = {k: :b}` returns 1. The ternary reports an always-falsey condition when the literal reading is
      # restored.
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

  describe "a Data or Struct construction rvalue on an untyped receiver" do
    it "keeps a Data instance as itself" do
      expect(dumped_type("Point = Data.define(:x)\ndef a(h, k) = dump_type(h[k] ||= Point.new(x: 1))\n"))
        .to eq("Point(x: 1)")
    end

    it "keeps a Struct instance as itself" do
      expect(dumped_type("Pair = Struct.new(:a)\ndef b(h, k) = dump_type(h[k] ||= Pair.new(1))\n"))
        .to eq("Pair(a: 1)")
    end
  end

  it "RESIDUAL: still reads the literal one level below a local the #2288 local bind erased" do
    # Runtime: `h = {k: {j: "s"}}` returns "S". `x` is `Hash[untyped, untyped]`, a tracked receiver like the
    # in-place-widened `pool = {}` of a block fold, so the literal reading stays (approval-queue.d entry for #2292).
    source = "def b(h, k)\n  x = (h[k] ||= {})\n  (x[:j] ||= 1).upcase\nend\n"
    expect(diagnostics_for(source).map(&:first)).to eq(["call.undefined-method"])
  end

  # Issue #2354 — a receiver whose type passes the #544 test but whose gradual slot another call may have filled:
  # an instance variable seeded `{}` in another method, a parameter declared `Hash[Symbol, untyped]`, or the value
  # of an outer `||=`. Only a local the current body binds keeps the literal reading.
  describe "a receiver that is no local the current body binds" do
    it "reports nothing on an instance variable another method seeds" do
      # Runtime: after `@cache[:k] = {name: "s"}`, `a(:k)` returns "S"; after `@cache[:k] = "s"`, `b(:k)` returns "S".
      expect(diagnostics_for(<<~RUBY)).to eq([])
        class Memo
          def initialize
            @cache = {}
          end

          def a(k) = (@cache[k] ||= {})[:name].upcase
          def b(k) = (@cache[k] ||= 1).upcase
        end
      RUBY
    end

    it "reports nothing on a parameter declared with an untyped value" do
      # Runtime: `c({k: {name: "s"}}, :k)` and `d({k: "s"}, :k)` return "S".
      result = analyze("class T\n  def c(h, k) = (h[k] ||= {})[:name].upcase\n  " \
                       "def d(h, k) = (h[k] ||= 1).upcase\nend\n",
                       sig: { "t.rbs" => "class T\n  def c: (Hash[Symbol, untyped], Symbol) -> untyped\n  " \
                                         "def d: (Hash[Symbol, untyped], Symbol) -> untyped\nend\n" })
      expect(result.diagnostics.reject { |d| d.severity.to_s == "info" }.map(&:rule)).to eq([])
    end

    it "reports nothing on the inner `||=` of an inline nest" do
      # Runtime: `nest_a({x: {y: {name: "s"}}}, :x, :y)` and `nest_b({x: {y: "s"}}, :x, :y)` return "S".
      source = "def nest_a(h, a, b) = ((h[a] ||= {})[b] ||= {})[:name].upcase\n" \
               "def nest_b(h, a, b) = ((h[a] ||= {})[b] ||= 1).upcase\n"
      expect(diagnostics_for(source)).to eq([])
    end

    it "unions a literal scalar rvalue with the unknown slot on an instance variable" do
      source = "class M\n  def initialize = @c = {}\n  def b(k) = dump_type(@c[k] ||= 1)\nend\n"
      expect(dumped_type(source)).to eq("1 | Dynamic[top]")
    end

    it "keeps the rvalue on a local the body binds to a gradual table (control)" do
      # Runtime: 1. `h` is the body's own fresh `Hash.new`, so no earlier call filled its slot.
      expect(dumped_type("def m(k)\n  h = Hash.new\n  dump_type(h[k] ||= 1)\nend\n")).to eq("1")
    end

    it "keeps the rvalue on a receiver fresh at every run (control)" do
      # Runtime: 1.
      expect(dumped_type("def m(k) = dump_type(Hash.new[k] ||= 1)\n")).to eq("1")
    end

    it "reports nothing on a parameter the body also writes, before, after or around the call" do
      # Runtime: `later({k: "s"}, :k)`, `branch({k: "s"}, :k, true)` and `shadow({k: "s"}, :k, [1])` return "S". A
      # parameter is the caller's object wherever else the body binds its name.
      rbs = "class P\n  " \
            "def later: (Hash[Symbol, untyped], Symbol) -> untyped\n  " \
            "def branch: (Hash[Symbol, untyped], Symbol, bool) -> untyped\n  " \
            "def shadow: (Hash[Symbol, untyped], Symbol, Array[Integer]) -> untyped\n" \
            "end\n"
      result = analyze(<<~RUBY, sig: { "p.rbs" => rbs })
        class P
          def later(h, k)
            r = (h[k] ||= 1).upcase
            h = {}
            r
          end

          def branch(h, k, f)
            h = h.dup if f
            (h[k] ||= 1).upcase
          end

          def shadow(h, k, xs)
            xs.each { |h| h }
            (h[k] ||= 1).upcase
          end
        end
      RUBY
      expect(result.diagnostics.reject { |d| d.severity.to_s == "info" }.map(&:rule)).to eq([])
    end

    it "reports nothing on an optional, keyword or destructured parameter the body rebinds" do
      # Runtime: `opt(:k, {k: "s"})`, `kw(:k, h: {k: "s"})` and `des([{k: "s"}, 0], :k)` return "S". A destructured
      # `h` reads `Dynamic[top]`, so `des` rebinds it to a typed table to reach the parameter-name test.
      rbs = "class R\n  " \
            "def opt: (Symbol, ?Hash[Symbol, untyped]) -> untyped\n  " \
            "def kw: (Symbol, h: Hash[Symbol, untyped]) -> untyped\n  " \
            "def des: ([Hash[Symbol, untyped], Integer], Symbol) -> untyped\n" \
            "end\n"
      result = analyze(<<~RUBY, sig: { "r.rbs" => rbs })
        class R
          def opt(k, h = {})
            h = h.dup
            (h[k] ||= 1).upcase
          end

          def kw(k, h:)
            h = h.dup
            (h[k] ||= 1).upcase
          end

          def des((h, x), k)
            h = {}.merge(h)
            (h[k] ||= 1).upcase
          end
        end
      RUBY
      expect(result.diagnostics.reject { |d| d.severity.to_s == "info" }.map(&:message)).to eq([])
    end

    it "ACCEPTED TRADE-OFF: goes silent on a block parameter that shadows a method parameter" do
      # Runtime: `sh({}, :k, [{}])` raises NoMethodError (`upcase` for 1). The block's `h` is named by the method's
      # parameter, so it widens like the parameter; approval-queue.d entry for #2354.
      rbs = "class S\n  def sh: (Hash[Symbol, untyped], Symbol, Array[Hash[Symbol, untyped]]) -> untyped\nend\n"
      result = analyze("class S\n  def sh(h, k, ys)\n    ys.each { |h| (h[k] ||= 1).upcase }\n  end\nend\n",
                       sig: { "s.rbs" => rbs })
      expect(result.diagnostics.reject { |d| d.severity.to_s == "info" }.map(&:rule)).to eq([])
    end

    it "ACCEPTED TRADE-OFF: goes silent on a parameter the body rebinds to a literal first" do
      # Runtime: NoMethodError (`upcase` for 1), since `h` is the body's own `{}` at the call. Any local named by a
      # parameter widens; approval-queue.d entry for #2354.
      rbs = "class Q\n  def m: (Hash[Symbol, untyped], Symbol) -> untyped\nend\n"
      result = analyze("class Q\n  def m(h, k)\n    h = {}\n    (h[k] ||= 1).upcase\n  end\nend\n",
                       sig: { "q.rbs" => rbs })
      expect(result.diagnostics.reject { |d| d.severity.to_s == "info" }.map(&:rule)).to eq([])
    end

    it "keeps the rvalue on a block parameter and on a pattern bind (control)" do
      # Runtime: `[1]` and 1. Both are names the body binds itself, so they keep the pre-#2354 reading.
      source = "def bp(k) = [Hash.new].map { |h| dump_type(h[k] ||= 1) }\n" \
               "def pat(k)\n  x = Hash.new\n  case x\n  in Hash => h then dump_type(h[k] ||= 1)\n  end\nend\n"
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      dumps = result.diagnostics.filter_map do |diagnostic|
        diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
      end
      expect(dumps).to eq(%w[1 1])
    end

    it "ACCEPTED TRADE-OFF: goes silent on the inner `||=` of a nest rooted at a body-local literal" do
      # Runtime: NoMethodError (`upcase` for 1), since `h` is empty on entry. The inner receiver is an expression,
      # so it widens like any other; approval-queue.d entry for #2354.
      expect(diagnostics_for("def m(a, b)\n  h = {}\n  ((h[a] ||= {})[b] ||= 1).upcase\nend\n")).to eq([])
    end
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
