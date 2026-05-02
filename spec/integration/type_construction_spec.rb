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

    it "binds `result` to the live-branch `Constant[:even]` when the predicate folds to true" do
      # `4.even?` constant-folds to `Constant[true]`, so the
      # else-branch is dead and the if-expression resolves to
      # `Constant[:even]` only. The bool-valued path (when the
      # receiver is a non-literal Integer) joins both edges into
      # `Constant[:even] | Constant[:odd]` — the fixture itself
      # `assert_type`s that case.
      expect(harness.local(:result)).to eq(constant(:even))
    end

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
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

    it "narrows the truthy/falsey branches via assert_type" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
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

    it "binds `strings` to a precise constant union of stringified literals" do
      # Union-fold lifts `[1,2,3].map { |n| n.to_s }` to
      # `Array[Union[Constant["1"], Constant["2"], Constant["3"]]]` —
      # strictly more precise than the previous `Array[String]`.
      # Wider receivers (e.g. `Nominal[Integer]`) still widen back
      # to `Array[String]` via the RBS tier.
      strings = harness.local(:strings)
      expect(strings).to be_a(Rigor::Type::Nominal)
      expect(strings.class_name).to eq("Array")
      element = strings.type_args.first
      expect(element).to be_a(Rigor::Type::Union)
      expect(element.members.map(&:value).sort).to eq(%w[1 2 3])
    end
  end

  describe "fixtures/early_return.rb — return-if-nil narrowing" do
    let(:harness) { harness_for("early_return") }

    it "drops nil from `String | nil` after the early-return guard via assert_type" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
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

  describe "fixtures/user_methods.rb — user-defined `is_odd` / `is_even` without RBS (v0.0.3 C)" do
    let(:harness) { harness_for("user_methods") }

    it "constant-folds the body so `Parity.new.is_odd(3)` returns `Constant[true]`" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/user_methods_with_sig/ — same class, but the sig declares the return type" do
    let(:harness) { harness_for("user_methods_with_sig") }

    it "self-asserts the engine resolves `bool` (`false | true`) for both helpers" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assert_extended/ — RBS::Extended `assert` / `assert-if-*` (v0.0.2)" do
    let(:harness) { harness_for("assert_extended") }

    it "narrows the argument unconditionally after a call annotated with `assert`" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assert_negation/ — RBS::Extended `~T` negation (v0.0.2 #2)" do
    let(:harness) { harness_for("assert_negation") }

    it "drops the negated class from the post-call union" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/self_predicate/ — RBS::Extended `target: self` narrowing (v0.0.2 #3)" do
    let(:harness) { harness_for("self_predicate") }

    it "narrows the receiver local for `predicate-if-*`, `assert-if-*`, and `assert` self-targeted directives" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/argument_type/ — argument-type-mismatch check rule (v0.0.2 #4)" do
    let(:harness) { harness_for("argument_type") }

    it "produces no diagnostics when every call argument matches its parameter type" do
      arg_errors = harness.errors.select { |d| d.message.start_with?("argument type mismatch") }
      expect(arg_errors).to be_empty
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

  describe "fixtures/divmod_tuple.rb — Integer#divmod folds to Tuple[Constant, Constant]" do
    let(:harness) { harness_for("divmod_tuple") }

    it "self-asserts via assert_type with no mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/integer_range_narrowing.rb — IntegerRange carrier and narrowing" do
    let(:harness) { harness_for("integer_range_narrowing") }

    it "self-asserts the comparison-narrowed range types via assert_type" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/container_size.rb — Array/String/Hash#size tightened to non_negative_int" do
    let(:harness) { harness_for("container_size") }

    it "self-asserts the tightened size return types via assert_type" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/file_path_folding.rb — File path-manipulation folding" do
    let(:harness) { harness_for("file_path_folding") }

    it "self-asserts every File.<path-method>(\"…\") fold" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/refinement_return_override/ — RBS::Extended return refinement" do
    let(:harness) { harness_for("refinement_return_override") }

    it "self-asserts non-empty-string and positive-int return overrides plus their projections" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/predicate_refinement/ — RBS::Extended predicate-subset return refinement" do
    let(:harness) { harness_for("predicate_refinement") }

    it "self-asserts lowercase/uppercase/numeric-string return overrides plus the case-fold projection pair" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/string_array_catalog.rb — String/Symbol/Array catalog-driven folding" do
    let(:harness) { harness_for("string_array_catalog") }

    it "self-asserts the new String/Symbol fold coverage" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/hash_catalog.rb — Hash catalog-driven folding" do
    let(:harness) { harness_for("hash_catalog") }

    it "self-asserts the new Hash catalog coverage (size projection, shape lookup, mutator widening)" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/range_catalog.rb — Range catalog-driven folding" do
    let(:harness) { harness_for("range_catalog") }

    it "self-asserts the new Range fold coverage" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/always_raises/ — division-by-zero diagnostic" do
    let(:harness) { harness_for("always_raises") }

    it "flags every Integer-by-zero call (suppressions in the fixture verify identification)" do
      # The fixture uses `# rigor:disable always-raises` on each
      # raising line, so a clean run proves both that the rule
      # fired AND that the suppression comment matches.
      raises = harness.errors.select { |d| d.rule == "always-raises" }
      expect(raises).to be_empty
    end
  end

  describe "fixtures/iterator_block_params.rb — IntegerRange-typed block parameters" do
    let(:harness) { harness_for("iterator_block_params") }

    it "self-asserts the precise per-iterator block-param ranges" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/union_arithmetic.rb — cartesian fold over Union[Constant…]" do
    let(:harness) { harness_for("union_arithmetic") }

    it "self-asserts the cartesian-fold and graceful-widening behaviours" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  # The fixtures below carry both an `assert_type` self-check
  # (so the file is readable as documentation) and the
  # finer-grained `harness.local` assertions above. The shared
  # spec here only verifies the assert_type path; the type-
  # specific assertions for each fixture live in their own
  # `describe` block.
  describe "self-asserting `assert_type` calls in converted fixtures" do
    %w[parity case_when compound_writes tuple_access hash_shape block_map].each do |name|
      it "produces no assert_type mismatches in fixtures/#{name}.rb" do
        harness = harness_for(name)
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end
  end
end
