# frozen_string_literal: true

require "spec_helper"

# Issue #2429 — when no overload matches a call's arguments, a call with a block falls back to an overload that
# declares one. The fallback took the first overload not requiring a block, so `URI.open(url, read_timeout: 3)
# { |io| ... }` (the keyword hash lands on `?String mode`, which matches neither arm) answered the block-less arm's
# `StringIO | Tempfile` rather than the block's value. Ruby: `URI.open("/etc/hosts", read_timeout: 3) { |io| 42 }`
# is `42`; `File.open("/etc/hosts") { |f| 1 }` is `1`.
RSpec.describe "Block-aware no-match overload fallback (#2429)", type: :runner do
  let(:sig) do
    { "r.rbs" => <<~RBS }
      class R
        def self.f: (String) -> Integer
                  | [T] (String) { () -> T } -> T
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

  it "binds a no-match block call to the block overload's return" do
    expect(dumped_types(<<~RUBY, sig: sig)).to eq([%("s")])
      dump_type(R.f(1) { "s" })
    RUBY
  end

  it "keeps the block-less overload for a no-match call without a block" do
    expect(dumped_types(<<~RUBY, sig: sig)).to eq(%w[Integer])
      dump_type(R.f(1))
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

  # `File.open` with five arguments matches neither arm (`call.wrong-arity` reports it); the block arm's `T` binds.
  it "binds File.open's block arm when the arguments match no overload" do
    expect(dumped_types(<<~RUBY)).to eq(%w[1])
      dump_type(File.open("x", "r", 1, 2, 3) { |f| 1 })
    RUBY
  end
end
