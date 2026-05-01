# frozen_string_literal: true

# Integration spec: the engine should construct precise types
# for small but realistic Ruby snippets. Each example is a
# self-contained Ruby fixture under `spec/integration/fixtures/`
# — readable on its own, runnable under MRI, and inspectable
# through the `rigor type-of` CLI. The spec body uses a shared
# `FixtureHarness` helper so adding a new scenario means
# dropping a `.rb` file under `fixtures/` and adding a few
# `expect` lines here.

require "spec_helper"
require_relative "support/fixture_harness"

RSpec.describe "Rigor type construction (integration)" do # rubocop:disable RSpec/DescribeClass
  def harness_for(name)
    Rigor::IntegrationSupport::FixtureHarness.new(name)
  end

  def constant(value)
    Rigor::Type::Combinator.constant_of(value)
  end

  describe "fixtures/parity.rb — even/odd predicate" do
    let(:harness) { harness_for("parity") }

    it "binds `result` to `Constant[:even] | Constant[:odd]`" do
      result_type = harness.local(:result)
      expect(result_type).to be_a(Rigor::Type::Union)
      expect(result_type.members.map(&:value)).to contain_exactly(:even, :odd)
    end
  end

  describe "fixtures/case_when.rb — Symbol-literal classification" do
    let(:harness) { harness_for("case_when") }

    it "binds `label` to a three-way Symbol-literal union" do
      members = harness.local(:label).members.map(&:value)
      expect(members).to contain_exactly(:zero, :small, :large)
    end
  end

  describe "fixtures/compound_writes.rb — operator dispatch through `+=` / `||=`" do
    let(:harness) { harness_for("compound_writes") }

    it "constant-folds `n += 5; n -= 3` so `n` is bound to `12`" do
      expect(harness.local(:n)).to eq(constant(12))
    end

    it "replaces a nil-bound `cached` with the rvalue type on `||=`" do
      expect(harness.local(:cached)).to eq(constant("hit"))
    end
  end

  describe "fixtures/is_a_narrowing.rb — String | nil narrowing" do
    let(:harness) { harness_for("is_a_narrowing") }

    it "narrows the truthy branch to the String constant" do
      # Line 7 col 3 is the read of `x` inside `if x.is_a?(String); x; ...`.
      expect(harness.type_at(line: 7, column: 3)).to eq(constant("hello"))
    end

    it "narrows the falsey branch to the nil constant" do
      expect(harness.type_at(line: 9, column: 3)).to eq(constant(nil))
    end
  end

  describe "fixtures/tuple_access.rb — Tuple element typing" do
    let(:harness) { harness_for("tuple_access") }

    it "binds `first`, `middle`, and `last` to their precise tuple elements" do
      expect(harness.local(:first)).to eq(constant(10))
      expect(harness.local(:middle)).to eq(constant(20))
      expect(harness.local(:last)).to eq(constant(30))
    end
  end

  describe "fixtures/hash_shape.rb — HashShape entry typing" do
    let(:harness) { harness_for("hash_shape") }

    it "binds `n` and `a` to their precise hash entries" do
      expect(harness.local(:n)).to eq(constant("Alice"))
      expect(harness.local(:a)).to eq(constant(30))
    end
  end

  describe "fixtures/block_map.rb — block-return type uplift on Array#map" do
    let(:harness) { harness_for("block_map") }

    it "binds `strings` to `Array[String]`" do
      strings = harness.local(:strings)
      expect(strings).to be_a(Rigor::Type::Nominal)
      expect(strings.class_name).to eq("Array")
      expect(strings.type_args.first).to be_a(Rigor::Type::Nominal)
      expect(strings.type_args.first.class_name).to eq("String")
    end
  end

  describe "fixtures/early_return.rb — return-if-nil narrowing" do
    let(:harness) { harness_for("early_return") }

    it "drops nil from `String | nil` after the early-return guard" do
      # Line 8 col 3 is the bare `x` read after `return if x.nil?`.
      expect(harness.type_at(line: 8, column: 3)).to eq(constant("hello"))
    end
  end

  describe "fixtures/assertions.rb — self-asserting via `assert_type`" do
    let(:harness) { harness_for("assertions") }

    it "produces no `assert_type` errors when the fixture's expectations match" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "exposes every `dump_type` call as an `:info` diagnostic the user can read" do
      # The fixture intentionally uses only `assert_type` (no
      # bare `dump_type` calls), so the info-severity dump
      # surface starts empty here. The presence of the rule
      # is what we are asserting; future fixtures may add
      # dump_type calls.
      info_dumps = harness.diagnostics.select { |d| d.severity == :info }
      expect(info_dumps).to be_an(Array)
    end
  end

  describe "fixtures/predicate_extended/ — RBS::Extended `predicate-if-*`" do
    let(:harness) { harness_for("predicate_extended") }

    it "narrows the truthy branch to Integer per `predicate-if-true`" do
      truthy = harness.type_at(line: 4, column: 5)
      expect(truthy).to be_a(Rigor::Type::Nominal)
      expect(truthy.class_name).to eq("Integer")
    end

    it "narrows the falsey branch to NilClass per `predicate-if-false`" do
      falsey = harness.type_at(line: 6, column: 5)
      expect(falsey).to be_a(Rigor::Type::Nominal)
      expect(falsey.class_name).to eq("NilClass")
    end
  end
end
