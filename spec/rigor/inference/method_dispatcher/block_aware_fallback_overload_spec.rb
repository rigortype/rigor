# frozen_string_literal: true

require "spec_helper"

# Issue #2429 — when no overload matches a call's arguments, a call with a block answers by the block-declaring
# overloads whose positional arity admits it: the one such arm, the return every such arm agrees on, or else
# `Dynamic[top]`. The fallback took the first overload not requiring a block, so `URI.open(url, read_timeout: 3)
# { |io| ... }` (the keyword hash lands on `?String mode`, which matches neither arm) answered the block-less arm's
# `StringIO | Tempfile` rather than the block's value. Ruby: `URI.open("/etc/hosts", read_timeout: 3) { |io| 42 }`
# is `42`; `[3, 1, 2].max_by(2.0) { |x| x }` is `[3, 2]`.
RSpec.describe "Block-aware no-match overload fallback (#2429)", type: :runner do
  let(:sig) do
    { "r.rbs" => <<~RBS }
      class R
        def self.f: (String) -> Integer
                  | [T] (String) { () -> T } -> T
      end
      class S
        def self.h: (Integer) -> Symbol
                  | (Integer, ?Integer) { (Integer) -> void } -> Integer
                  | (String, ?String) { (String) -> void } -> String
        def self.g: (Integer) -> Symbol
                  | (Integer) { (Integer) -> void } -> String
                  | (String) { (String) -> void } -> String
      end
    RBS
  end

  let(:fetch_sig) do
    { "fetch.rbs" => <<~RBS }
      class Fetch
        def fetch: (String) -> String
        def control: (String) -> Integer
      end
    RBS
  end

  def dumped_types(source, sig: {})
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def return_mismatches(source)
    analyze(source, sig: fetch_sig).diagnostics.select { |d| d.qualified_rule == "def.return-type-mismatch" }
  end

  it "binds a no-match block call to the one block overload's return" do
    expect(dumped_types(<<~RUBY, sig: sig)).to eq([%("s")])
      dump_type(R.f(1) { "s" })
    RUBY
  end

  it "keeps the block-less overload for a no-match call without a block" do
    expect(dumped_types(<<~RUBY, sig: sig)).to eq(%w[Integer])
      dump_type(R.f(1))
    RUBY
  end

  # Both block arms admit two positionals and disagree, so position does not decide between them.
  it "answers Dynamic[top] when the admissible block overloads disagree" do
    result = analyze(<<~RUBY, sig: sig)
      require "rigor/testing"
      include Rigor::Testing
      r = S.h("a", strict: true) { |s| s.upcase }
      dump_type(r)
      r.upcase
    RUBY
    expect(result.diagnostics.map(&:qualified_rule)).not_to include("call.undefined-method")
    expect(result.diagnostics.filter_map { |d| d.message[/dump_type: (.*)/, 1] }).to eq(["Dynamic[top]"])
  end

  it "uses the return the admissible block overloads agree on" do
    expect(dumped_types(<<~RUBY, sig: sig)).to eq(%w[String])
      dump_type(S.g(1.0) { |x| x })
    RUBY
  end

  it "takes the block overload whose arity admits the call (max_by(2.0))" do
    result = analyze(<<~RUBY)
      require "rigor/testing"
      include Rigor::Testing
      top = [3, 1, 2].max_by(2.0) { |x| x }
      dump_type(top)
      top.size
    RUBY
    expect(result.diagnostics.map(&:qualified_rule)).not_to include("call.possible-nil-receiver")
    expect(result.diagnostics.filter_map { |d| d.message[/dump_type: (.*)/, 1] }).to eq(["Array[1 | 2 | 3]"])
  end

  it "answers Dynamic[top] when no block overload's arity admits the call" do
    expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
      dump_type(File.open("x", "r", 1, 2, 3) { |f| 1 })
    RUBY
  end

  it "leaves a no-match call's block parameters untyped" do
    expect(dumped_types(<<~RUBY, sig: sig)).to eq(["Dynamic[top]"] * 4)
      [3, 1, 2].max_by(2.0) { |x| dump_type(x) }
      File.open("x", "r", 1, 2, 3) { |f| dump_type(f) }
      S.g(1.0) { |x| dump_type(x) }
      R.f(1) { |*a| dump_type(a.first) }
    RUBY
  end

  # The second call, without keywords, matches the block arm in the passes and was `1` before #2429 too (guard).
  it "types URI.open with keywords and a block by the block's value" do
    expect(dumped_types(<<~RUBY)).to eq(%w[1 1])
      require "open-uri"
      dump_type(URI.open("u", read_timeout: 3) { |io| 1 })
      dump_type(URI.open("u") { |io| 1 })
    RUBY
  end

  # Guard: each call matches in the passes, so the fallback never runs; the types are base's.
  it "keeps the matched block and block-less selections" do
    expected = ["decimal-int-string", "Array[Integer]", "Enumerator[Array[1 | 2 | 3], Array[Integer]]",
                "Enumerator[1 | 2, Array[1 | 2]]"]
    expect(dumped_types(<<~RUBY)).to eq(expected)
      dump_type(1.then { |x| x.to_s })
      dump_type([1, 2, 3].each_slice(2) { |s| s })
      dump_type([1, 2, 3].each_slice(2))
      dump_type([1, 2].filter)
    RUBY
  end

  it "reports no return-type mismatch on a block URI.open whose block answers the declared type" do
    expect(return_mismatches(<<~RUBY)).to eq([])
      require "open-uri"

      class Fetch
        def fetch(url)
          URI.open(url, read_timeout: 3) { |io| io.read.to_s }
        end
      end
    RUBY
  end

  # Guard: the block-less call matches its arm in the passes, so the fallback never runs; it must stay a true positive.
  it "still reports a block-less URI.open against a declared Integer" do
    expect(return_mismatches(<<~RUBY).map(&:message)).to contain_exactly(include("StringIO | Tempfile"))
      require "open-uri"

      class Fetch
        def control(url) = URI.open(url)
      end
    RUBY
  end
end
