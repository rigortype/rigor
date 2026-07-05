# frozen_string_literal: true

require "spec_helper"
require "rigor/protection/mutator"

# ADR-63 Tier 2 — the type-visible mutation generator productized from the dev harness. Generates byte-range source
# splices aimed at the call-rule families, and (with the type-aware filter) keeps only mutations at sites where Rigor
# holds a concrete receiver type.
RSpec.describe Rigor::Protection::Mutator do
  def mutations(source, **)
    described_class.new(source, **).mutations
  end

  it "renames a call site on an explicit receiver (undefined-method channel)" do
    muts = mutations(%("hi".upcase\n))
    rename = muts.find { |m| m.operator == :undefined_method }
    expect(rename).not_to be_nil
    expect(rename.apply(%("hi".upcase\n))).to eq(%("hi".upcase__rigor_absent\n))
  end

  it "drops and type-swaps a call-argument literal (argument-type-mismatch channel)" do
    muts = mutations(%(foo.bar(1)\n)).select { |m| %i[nil_inject type_swap].include?(m.operator) }
    expect(muts.map(&:operator)).to contain_exactly(:nil_inject, :type_swap)
    nil_mut = muts.find { |m| m.operator == :nil_inject }
    expect(nil_mut.apply(%(foo.bar(1)\n))).to eq(%(foo.bar(nil)\n))
  end

  it "excludes arity_extra from the default operator set (noise on variadic methods)" do
    expect(mutations(%(foo.bar(1)\n)).map(&:operator)).not_to include(:arity_extra)
    with_arity = mutations(%(foo.bar(1)\n), operators: described_class::ALL_OPERATORS)
    expect(with_arity.map(&:operator)).to include(:arity_extra)
  end

  it "does not mutate an argument to a universal-equality method (always an equivalent mutant)" do
    expect(mutations(%(x == 1\n)).select { |m| %i[nil_inject type_swap].include?(m.operator) }).to be_empty
  end

  it "returns no mutations for unparseable source" do
    expect(mutations("def foo(\n")).to eq([])
  end

  describe "#filter_by_type" do
    def filter(source)
      mutator = described_class.new(source)
      mutator.filter_by_type(mutator.mutations, environment: Rigor::Environment.default, path: "(spec).rb")
    end

    it "keeps a mutation whose receiver types concrete and records the rendered type" do
      kept, dropped = filter(%("hello".upcase\n))
      rename = kept.find { |m| m.operator == :undefined_method }
      expect(rename).not_to be_nil
      expect(rename.anchor_type).to be_a(String)
      expect(dropped).to be >= 0
    end

    it "drops a mutation on an untyped (Dynamic) receiver" do
      kept, dropped = filter(<<~RUBY)
        def f(x)
          x.save(1)
        end
      RUBY
      expect(kept).to be_empty
      expect(dropped).to be >= 1
    end
  end
end
