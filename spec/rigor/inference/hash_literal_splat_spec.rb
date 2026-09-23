# frozen_string_literal: true

require "spec_helper"

# A hash literal with a `**splat` entry typed as if the splat were absent: `o = { a: :z }; h = { **o, b: :y }`
# read `Hash[:b, :y]` while Ruby builds `{ a: :z, b: :y }`, so a read of a splatted key folded on correct code.
# The literal now joins each splatted entry's key and value types into its `Hash[K, V]`.
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
  def reported_rules(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
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
    expect(dumped_types(<<~RUBY)).to eq(["Hash[:a | :b, :y | :z]", "Hash[:a, :z]"])
      o = { a: :z }
      dump_type({ **o, b: :y })
      dump_type({ **o })
    RUBY
  end

  it "joins a splatted Hash[K, V]'s type arguments" do
    expect(dumped_types(<<~RUBY, sig: store_sig)).to eq(["Hash[:b | String, :y | Integer]"])
      dump_type({ **Store.counts, b: :y })
    RUBY
  end

  it "adds a Dynamic[top] arm for a splat it cannot read" do
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

  it "still folds the splat-free literal's impossible comparison" do
    # The positive control for the silence above. The rule id names the family, not the direction: its
    # message says "always falsey".
    expect(reported_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
      h = { b: :y }
      puts "a first" if h.keys.first == :a
    RUBY
  end
end
