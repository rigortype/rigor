# frozen_string_literal: true

require "spec_helper"

# A hash literal with a `**splat` entry typed as if the splat were absent: `o = { a: :z }; h = { **o, b: :y }`
# read `Hash[:b, :y]` while Ruby builds `{ a: :z, b: :y }`, so a read of a splatted key folded on correct code.
# The literal now joins each splatted entry's key and value types into its `Hash[K, V]`, with a `Dynamic[top]`
# arm on each side: the literal is a new hash no declaration describes, and a precise `Hash[K, V]` is one
# `MutationRejoin` never regrows, so a copy the code then writes into would fold instead.
#
# The splat-free literal is the control: it stays the exact `HashShape` it always was.
RSpec.describe "A hash literal with a **splat entry", type: :runner do
  def dumped_types(source, sig: {})
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  # Every error-severity rule plus the always-truthy / always-falsey family.
  def reported_rules(source, sig: {})
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.rule if diagnostic.severity == :error || diagnostic.rule.to_s.start_with?("flow.")
    end
  end

  let(:store_sig) do
    { "store.rbs" => <<~RBS }
      class Store
        def self.counts: () -> Hash[String, Integer]
      end
    RBS
  end

  it "keeps a splat-free literal an exact shape" do
    expect(dumped_types(<<~RUBY)).to eq(["{ a: :z, b: :y }"])
      dump_type({ a: :z, b: :y })
    RUBY
  end

  it "joins a splatted shape's keys and values into the literal's Hash[K, V]" do
    # Runtime `{ a: :z, b: :y }` and `{ a: :z }`.
    expected = ["Hash[:a | :b | Dynamic[top], :y | :z | Dynamic[top]]", "Hash[:a | Dynamic[top], :z | Dynamic[top]]"]
    expect(dumped_types(<<~RUBY)).to eq(expected)
      o = { a: :z }
      dump_type({ **o, b: :y })
      dump_type({ **o })
    RUBY
  end

  it "joins a splatted Hash[K, V]'s type arguments" do
    expected = ["Hash[:b | Dynamic[top] | String, :y | Dynamic[top] | Integer]"]
    expect(dumped_types(<<~RUBY, sig: store_sig)).to eq(expected)
      dump_type({ **Store.counts, b: :y })
    RUBY
  end

  it "adds only the Dynamic[top] arm for a splat it cannot read" do
    expect(dumped_types(<<~RUBY)).to eq(["Hash[:b | Dynamic[top], :y | Dynamic[top]]"] * 2)
      def merge(opts)
        dump_type({ **opts, b: :y })
      end

      def forward(**)
        dump_type({ **, b: :y })
      end
    RUBY
  end

  it "no longer folds a read of a splatted key on correct code" do
    # THE REPORTED HAZARD: `h.keys` read `Array[:b]` and `h[:a]` read `:y | nil`, so both comparisons folded
    # always-falsey.
    expect(reported_rules(<<~RUBY)).to be_empty
      o = { a: :z }
      h = { **o, b: :y }
      puts "a first" if h.keys.first == :a
      puts "a is z" if h[:a] == :z
    RUBY
  end

  # A splat-only literal typed as the raw `Hash` before, so none of these folded; a precise `Hash[K, V]` would
  # have made every one of them fold, two at error severity. The mixed literal (the last pair) folded before.
  it "does not fold a read of what the code writes into the copy" do
    expect(reported_rules(<<~RUBY, sig: store_sig)).to be_empty
      DEFAULTS = { retries: 3 }
      o = DEFAULTS.dup
      h1 = { **o }
      h1[:b] = 2
      puts "stored" if h1[:b] == 2
      h2 = { **o }
      h2[:e] = "s"
      puts h2[:e].upcase
      h3 = { **DEFAULTS }
      h3[:retries] += 1
      puts "four" if h3[:retries] == 4
      h4 = { **o }
      h4.merge!(b: :sym)
      puts "merged" if h4[:b] == :sym
      h5 = { **Store.counts }
      h5["name"] = "str"
      puts h5["name"].upcase
      h6 = { **o, b: 2 }
      h6[:c] = 3
      puts "mixed" if h6[:c] == 3
    RUBY
  end

  # The literal's `Dynamic[top]` arm says the analysis could not read every entry, so a record the runtime value
  # satisfies is not a mismatch. `{ **BASE, b: 2 }` reported `def.return-type-mismatch` against
  # `-> { a: Integer, b: Integer }` both before the splat was read and after.
  describe "against a declared record" do
    let(:rec_sig) do
      { "rec.rbs" => <<~RBS }
        class Rec
          def rec: () -> { a: Integer, b: Integer }
          def rec_nominal: (Hash[Symbol, Integer]) -> { a: Integer, b: Integer }
          def take: ({ a: Integer, b: Integer }) -> void
          def control: () -> { a: Integer, b: Integer }
          def pick: ({ a: Integer }) -> Integer
                  | (Hash[Symbol, untyped]) -> String
          def pick_all: (Array[{ a: Integer }]) -> Integer
                      | (Array[Hash[Symbol, untyped]]) -> String
          def mix: ({ a: Integer, b: Object, c: Base }) -> Integer
                 | (Hash[Symbol, untyped]) -> String
        end
        class Base
        end
      RBS
    end

    def mismatch_rules(source)
      analyze(source, sig: rec_sig).diagnostics.map(&:rule).grep(/mismatch/)
    end

    def errors(source)
      analyze(source, sig: rec_sig).diagnostics.select { |d| d.severity == :error }.map { |d| [d.rule, d.line] }
    end

    it "does not report a splatted literal the record describes" do
      expect(mismatch_rules(<<~RUBY)).to be_empty
        class Rec
          BASE = { a: 1 }.freeze

          def rec
            { **BASE, b: 2 }
          end

          def rec_nominal(opts)
            { **opts, b: 2 }
          end

          def take(record); end

          def caller_site
            # An explicit receiver: the argument check does not run on an implicit-self call.
            self.take({ **BASE, b: 2 })
          end

          def control
            { a: 1, b: 2 }
          end
        end
      RUBY
    end

    it "still reports a splat-free literal the record rejects" do
      # The positive controls: the exact shape keeps its verdict, as a return and as an argument.
      expect(mismatch_rules(<<~RUBY)).to eq(%w[def.return-type-mismatch call.argument-type-mismatch])
        class Rec
          def control
            { a: "x", b: 2 }
          end

          def take(record); end

          def caller_site
            self.take({ a: "x", b: 2 })
          end
        end
      RUBY
    end

    # A record parameter's `maybe` is no evidence for its overload: the strict pass must not take it over a
    # `Hash` overload that answers yes. `{ **BASE, b: 2 }` has a key the closed record forbids, and the runtime
    # takes the `Hash[Symbol, untyped]` overload.
    it "does not let a record overload listed first win a splatted literal by position" do
      # Only the control on line 8 (`Integer#upcase`) fires.
      expect(errors(<<~RUBY)).to eq([["call.undefined-method", 8]])
        class Rec
          BASE = { a: 1 }.freeze

          def pick(value) = value.is_a?(Hash) && value.size == 1 ? 1 : "s"

          def picks
            self.pick({ **BASE, b: 2 }).upcase
            self.pick({ a: 1 }).upcase
          end
        end
      RUBY
    end

    it "does not let a record nested in a parameter win a splatted literal by position" do
      # Only the control on line 8 (`Integer#upcase`) fires.
      expect(errors(<<~RUBY)).to eq([["call.undefined-method", 8]])
        class Rec
          BASE = { a: 1 }.freeze

          def pick_all(values) = values.all? { |value| value.size == 1 } ? 1 : "s"

          def picks
            self.pick_all([{ **BASE, b: 2 }]).upcase
            self.pick_all([{ a: 1 }]).upcase
          end
        end
      RUBY
    end

    # The discount is for the record's own `maybe` against the splatted `Hash`. Here the splat sits under a
    # parameter that is no record (`b: Object`), and the record's `maybe` comes from `c:`, where `Sub` is a
    # subclass only the Ruby source declares. That `maybe` still counts, so the record overload keeps the strict
    # pass.
    it "keeps a record overload whose maybe does not come from the splatted literal" do
      expect(errors(<<~RUBY)).to be_empty
        class Sub < Base
        end

        class Rec
          BASE = { k: 1 }.freeze

          def mix(_h) = 1

          def mixes
            self.mix({ a: 1, b: { **BASE, z: 2 }, c: Sub.new }).even?
          end
        end
      RUBY
    end
  end

  it "still folds the splat-free literal's impossible comparison" do
    # The positive control for the silence above. The rule id names the family, not the direction: its
    # message says "always falsey".
    expect(reported_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
      h = { b: :y }
      puts "a first" if h.keys.first == :a
    RUBY
  end
end
