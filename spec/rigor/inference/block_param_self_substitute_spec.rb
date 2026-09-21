# frozen_string_literal: true

require "spec_helper"

# Issue #1130 — a `-> self`-shaped block parameter (`Object#tap` yields `self`) must see the receiver's
# type arguments through the same {SelfSubstitute} keep-vs-degrade verdict the return path applies
# (#1092). Before the fix the block-param probe built `self_type` from the class name alone, so
# `ints.tap { |a| }` bound `a` to a raw `Array` while the call returned `Array[Integer]`, and
# `[1, 2].tap { |a, b| }` fell onto #1128's `Dynamic[top]` floor. The block path reuses only the
# verdict, not the return path's value-pin widening: `[1, 2].tap { |a, b| }` binds the pinned element
# union `1 | 2` per slot with the ADR-101 optimistic mark — the parity the block auto-splat of
# `Array[T]` already gives (`each_slice(2)` binds `T` per slot) — and a mutator the verdict declines
# keeps the raw nominal. The return path stays the control.
RSpec.describe "block parameters share the `-> self` substitution verdict", type: :runner do
  def analyzed(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
  end

  def assert_type_mismatches(source)
    analyzed(source).diagnostics.filter_map do |diagnostic|
      diagnostic.message if diagnostic.message.start_with?("assert_type mismatch")
    end
  end

  let(:ints) { "ints = (1..rand(9)).to_a" }

  it "binds `ints.tap { |a| }` to Array[Integer] like the return path does" do
    expect(assert_type_mismatches(<<~RUBY)).to eq([])
      #{ints}
      ints.tap { |a| assert_type("Array[Integer]", a) }
    RUBY
  end

  it "binds `[1, 2].tap { |a, b| }` to the pinned element union per slot, matching the `each_slice(2)` splat" do
    expect(assert_type_mismatches(<<~RUBY)).to eq([])
      [1, 2].tap { |a, b| assert_type("1 | 2", a); assert_type("1 | 2", b) }
    RUBY
  end

  it "keeps the union on the single-parameter form, matching the explicit `a, b = [1, 2]` element family" do
    expect(assert_type_mismatches(<<~RUBY)).to eq([])
      [1, 2].tap { |pair| assert_type("Array[1 | 2]", pair) }
    RUBY
  end

  it "leaves an argument-free raw receiver's block parameter raw (mutator result included)" do
    expect(assert_type_mismatches(<<~RUBY)).to eq([])
      raw = [1, 2].map! { |i| i.to_s }
      raw.tap { |a| assert_type("Array", a) }
      bare = Array.new
      bare.tap { |a| assert_type("Array", a) }
    RUBY
  end

  it "keeps the mutator-vs-non-mutator verdict on a user `-> self` block parameter" do
    source = <<~RUBY
      require "rigor/testing"
      include Rigor::Testing
      box = SubBoxMaker.pack(1)
      box.pure { |b| assert_type("SubBox[Integer]", b) }
      box.rewrite! { |b| assert_type("SubBox", b) }
    RUBY
    diagnostics = analyze(
      source,
      sig: {
        "sub_box.rbs" => <<~RBS
          class SubBox[A]
            def pure: () { (self) -> void } -> self
            def rewrite!: () { (self) -> void } -> self
          end

          class SubBoxMaker
            def self.pack: (Integer) -> SubBox[Integer]
          end
        RBS
      }
    ).diagnostics
    expect(diagnostics.filter_map { |d| d.message if d.message.start_with?("assert_type mismatch") })
      .to eq([])
  end
end
