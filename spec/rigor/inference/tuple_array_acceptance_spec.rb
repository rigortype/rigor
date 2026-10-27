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

  # Issue #2428 round 2 — pass 1 declines when a competing overload's parameter is an alias, an interface or
  # `untyped`, and pass 2 then took the tuple overload by list position on its `maybe`. Pass 2 now takes the first
  # match that does not rest on that `maybe`.
  describe "in the gradual overload pass" do
    let(:gradual_sig) do
      { "g.rbs" => <<~RBS }
        interface _MyEach[T]
          def each: () { (T) -> void } -> void
        end
        class G
          def self.i: ([String, String]) -> Symbol
                    | (_MyEach[String]) -> String
          def self.al: ([Integer, Integer]) -> Symbol
                     | (array[Integer]) -> String
          def self.u: ([Integer, Integer]) -> Symbol
                    | (untyped) -> String
          def self.gen: [A, B] ([A, B]) -> A
                      | [X] (array[X]) -> String
          def self.rec: ({ a: Integer }, Array[Integer]) -> Symbol
                      | (_MyEach[untyped], Array[Integer]) -> String
          def self.probe: (Array[String], Array[Integer]) -> void
          def self.probe_rec: (Hash[Symbol, untyped], Array[Integer]) -> void
          def self.kw: (pair: [Integer, Integer]) -> Symbol
                     | (pair: untyped) -> String
          def self.kw2: (Integer, pair: [Integer, Integer]) -> Symbol
                      | (Integer, pair: untyped) -> String
          def self.kw3: (pair: [Integer, Integer]) -> Symbol
                      | (pair: Array[Integer]) -> String
          def self.kw4: (pair: [Integer, Integer]) -> Symbol
                      | (pair: _Each[Integer]) -> String
          def self.probe_kw: (Array[Integer]) -> void
        end
      RBS
    end

    it "takes the overload the Array matches without the tuple's maybe" do
      expect(rules(<<~RUBY, sig: gradual_sig)).to be_empty
        require "rigor/testing"
        include Rigor::Testing

        class G
          def self.probe(s, a)
            assert_type("String", G.i(s))
            assert_type("String", G.al(a))
            assert_type("String", G.u(a))
            assert_type("String", G.gen(a))
            assert_type("Symbol", G.u([1, 2]))
            nil
          end

          # A record's `maybe` for an unread hash is not re-asked: the record overload keeps its gradual-pass win.
          def self.probe_rec(h, a)
            assert_type("Symbol", G.rec(h, a))
            nil
          end
        end
      RUBY
    end

    # Pass 1.5 checks keywords gradually, so it refuses the tuple's `maybe` too and leaves the choice to pass 2.
    # `kw3` (an `Array[Integer]` competitor) and the literal pair are controls.
    it "takes the keyword overload the Array matches without the tuple's maybe" do
      expect(rules(<<~RUBY, sig: gradual_sig)).to be_empty
        require "rigor/testing"
        include Rigor::Testing

        class G
          def self.probe_kw(a)
            assert_type("String", G.kw(pair: a))
            assert_type("String", G.kw2(1, pair: a))
            assert_type("String", G.kw3(pair: a))
            assert_type("String", G.kw4(pair: a))
            assert_type("Symbol", G.kw(pair: [1, 2]))
            nil
          end
        end
      RUBY
    end

    # The vendored redis signature declares `hmget: (arg, [arg]) -> [String?]` before
    # `(arg, Array[arg]) -> Array[String?]`. Reading the first folded `vals.size` to `1` and reported
    # `vals.size == 2` as always falsey.
    it "types redis hmget with an Array of fields by its Array overload" do
      expect(rules(<<~RUBY, sig: { "f.rbs" => "class F\n  def go: (Array[String]) -> Symbol?\nend\n" })).to be_empty
        require "redis"
        require "rigor/testing"
        include Rigor::Testing

        class F
          def go(fields)
            vals = Redis.new.hmget("k", fields)
            assert_type("Array[String?]", vals)
            return :two if vals.size == 2

            nil
          end
        end
      RUBY
    end
  end
end
