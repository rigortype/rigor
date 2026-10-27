# frozen_string_literal: true

require "spec_helper"

# Issue #2428 — a tuple parameter rejected every `Array[E]` argument outright, so `URI.encode_www_form`'s
# `Enumerable[[_ToS, _ToS]]` drew `call.argument-type-mismatch` on the `Array[Array[String]]` that
# `URI.decode_www_form` answers. An `Array[E]` has unknown arity, so the tuple answers `maybe` unless some position
# rejects every member of `E`.
RSpec.describe "A tuple parameter against an Array argument", type: :runner do
  def rules(source, sig: probe_sig)
    analyze(source, sig: sig).diagnostics.map { |d| [d.rule.to_s, d.line] }
  end

  let(:probe_sig) do
    { "probe.rbs" => <<~RBS }
      class Probe
        def nominal_nested: (Array[Array[String]]) -> String
        def gradual_pair: (Array[untyped]) -> String
        def self.takes_pair: ([Integer, Integer]) -> Integer
        def self.contradict: (Array[String]) -> Integer
        def self.agree: (Array[Integer]) -> Integer
        def self.mixed: (Array[Integer | String]) -> Integer
        def ret_tuple: (Array[String]) -> [String, String]
        def ret_contradict: (Array[Symbol]) -> [String, String]
      end
      class Ov
        def self.f: ([Integer, Integer]) -> Symbol
                  | (Array[Integer]) -> String
      end
    RBS
  end

  it "accepts the decode, filter and push round trip through URI.encode_www_form" do
    expect(rules(<<~RUBY)).to be_empty
      require "uri"

      class Probe
        def round_trip(s)
          q = URI.decode_www_form(s).delete_if { |k, _| k == "x" }
          q << ["a", "b"]
          URI.encode_www_form(q)
        end

        def nominal_nested(q)
          URI.encode_www_form(q)
        end

        def gradual_pair(pair)
          URI.encode_www_form([pair])
        end
      end
    RUBY
  end

  it "still reports an argument that is no Enumerable at all" do
    expect(rules(<<~RUBY)).to eq([["call.argument-type-mismatch", 4]])
      require "uri"

      class Probe
        def control = URI.encode_www_form(1)
      end
    RUBY
  end

  it "still reports an Array whose element a tuple position rejects" do
    expect(rules(<<~RUBY)).to eq([["call.argument-type-mismatch", 3]])
      class Probe
        def self.takes_pair(pair) = pair.first
        def self.contradict(a) = Probe.takes_pair(a)
        def self.agree(a) = Probe.takes_pair(a)
        def self.mixed(a) = Probe.takes_pair(a)
      end
    RUBY
  end

  # The accepted cost (ADR-5): the arity is unknown, so a wrong-length `Array[E]` where a tuple is declared goes
  # unreported. `ret_tuple(["a"])` returns a one-element array. An element contradiction is still reported.
  it "does not report a declared tuple return fed by a plain Array of a fitting element" do
    expect(rules(<<~RUBY)).to eq([["def.return-type-mismatch", 3]])
      class Probe
        def ret_tuple(a) = a
        def ret_contradict(a) = a
      end
    RUBY
  end

  # The `maybe` is no evidence for an overload: the strict pass still takes the `Array` overload by proof rather
  # than the tuple one by list position.
  it "keeps the strict overload pass on the Array overload" do
    expect(rules(<<~RUBY)).to be_empty
      require "rigor/testing"
      include Rigor::Testing

      class Probe
        def self.agree(a)
          assert_type("String", Ov.f(a))
          assert_type("Symbol", Ov.f([1, 2]))
          1
        end
      end
    RUBY
  end
end
