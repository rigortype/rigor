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

  describe "fixtures/tuple_map.rb — per-element block fold for :map / :collect on Tuple" do
    let(:harness) { harness_for("tuple_map") }

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "folds heterogeneous Tuple#map into per-position Tuple of stringified constants" do
      mixed = harness.local(:mixed)
      expect(mixed).to be_a(Rigor::Type::Tuple)
      expect(mixed.elements.map(&:value)).to eq(%w[1 two three])
    end

    it "folds Tuple#collect (the :map alias) the same way" do
      collected = harness.local(:collected)
      expect(collected).to be_a(Rigor::Type::Tuple)
      expect(collected.elements.map(&:value)).to eq([15, 25])
    end
  end

  describe "fixtures/block_filter.rb — BlockFolding for select/all?/any?" do
    let(:harness) { harness_for("block_filter") }

    it "produces no assert_type mismatches" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end

    it "folds `[10, 20].any? { |x| x > 0 }` to Constant[true]" do
      expect(harness.local(:non_empty_any)).to eq(constant(true))
    end

    it "folds `[1,2,3].select { false }` to the empty tuple" do
      expect(harness.local(:empty_select)).to eq(Rigor::Type::Combinator.tuple_of)
    end

    it "folds `[1,2,3].all? { true }` to Constant[true]" do
      expect(harness.local(:all_truthy)).to eq(constant(true))
    end
  end

  describe "fixtures/block_map.rb — per-position Tuple uplift on Array#map" do
    let(:harness) { harness_for("block_map") }

    it "binds `strings` to a per-position Tuple of stringified literals" do
      # v0.0.6 phase 2 — `[1,2,3].map { |n| n.to_s }` folds to
      # `Tuple[Constant["1"], Constant["2"], Constant["3"]]`,
      # strictly tighter than the previous Array[union] projection.
      # Wider receivers (e.g. `Nominal[Integer]`) still widen back
      # to `Array[String]` via the RBS tier.
      strings = harness.local(:strings)
      expect(strings).to be_a(Rigor::Type::Tuple)
      expect(strings.elements.map(&:value)).to eq(%w[1 2 3])
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

  describe "fixtures/parameterised_refinement/ — RBS::Extended parameterised return payload" do
    let(:harness) { harness_for("parameterised_refinement") }

    it "self-asserts non-empty-array[T], non-empty-hash[K, V], and int<a, b> return overrides" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/intersection_refinement/ — composite Intersection-backed refinements" do
    let(:harness) { harness_for("intersection_refinement") }

    it "self-asserts non-empty-lowercase-string and non-empty-uppercase-string + size projection" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assert_refinement/ — RBS::Extended assert against a refinement" do
    let(:harness) { harness_for("assert_refinement") }

    it "substitutes the refinement carrier for the target's bound type after the call" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assert_negation_refinement/ — RBS::Extended assert against ~refinement" do
    let(:harness) { harness_for("assert_negation_refinement") }

    it "narrows the target to the complement of the refinement (Difference[String, \"\"] → Constant[\"\"])" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/assert_negation_integer_range/ — RBS::Extended assert against ~int<a, b>" do
    let(:harness) { harness_for("assert_negation_integer_range") }

    it "narrows Integer to the union of the two open complement halves" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/param_extended/ — RBS::Extended rigor:v1:param: directive" do
    let(:harness) { harness_for("param_extended") }

    it "flags exactly the call site whose argument fails the refinement (suppression verifies identification)" do
      # The fixture uses `# rigor:disable argument-type-mismatch`
      # on the offending call, so a clean run proves both that
      # the rule fired against the override AND that the
      # suppression-comment matches.
      arg_errors = harness.errors.select { |d| d.message.start_with?("argument type mismatch") }
      expect(arg_errors).to be_empty
    end

    it "applies the override inside the method body via MethodParameterBinder" do
      # `assert_type` calls inside `normalise(id)` exercise the
      # body-side narrowing: the binder must read the same
      # override map and bind `id` to `non-empty-string` rather
      # than the RBS-declared `String`. A miss surfaces as an
      # `assert_type mismatch` diagnostic.
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

  describe "fixtures/set_catalog.rb — Set catalog-driven folding" do
    let(:harness) { harness_for("set_catalog") }

    it "self-asserts the Set#size projection plus blocklisted mutators" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/time_catalog.rb — Time catalog-driven folding" do
    let(:harness) { harness_for("time_catalog") }

    it "self-asserts the Time reader surface plus blocklisted in-place mutators" do
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

  describe "fixtures/each_with_index.rb — Enumerable-aware block-parameter typing" do
    let(:harness) { harness_for("each_with_index") }

    it "self-asserts the element + non-negative-int index for Array / Hash / Range receivers" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/enumerable_memo.rb — each_with_object / inject / reduce" do
    let(:harness) { harness_for("enumerable_memo") }

    it "self-asserts memo-typed block parameters across each_with_object, inject (with + without seed), and reduce" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/enumerable_collect.rb — group_by / partition / each_slice / each_cons" do
    let(:harness) { harness_for("enumerable_collect") }

    it "self-asserts the precise per-position element union for Tuple-shaped receivers" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/include_aware_clamp.rb — Integer#clamp via Comparable's catalog" do
    let(:harness) { harness_for("include_aware_clamp") }

    it "folds Integer#clamp through the include-aware module-catalog fallthrough" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/two_arg_fold.rb — 2-arg constant folding (between?/clamp/pow)" do
    let(:harness) { harness_for("two_arg_fold") }

    it "folds Comparable#between?, Comparable#clamp(min, max), and Integer#pow(exp, mod)" do
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

  describe "fixtures/date_catalog/ — Date / DateTime catalog-driven folding" do
    let(:harness) { harness_for("date_catalog") }

    it "self-asserts the Date / DateTime reader and navigation surface" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/rational_catalog.rb — Rational catalog-driven folding" do
    let(:harness) { harness_for("rational_catalog") }

    it "self-asserts the new Rational catalog coverage" do
      mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
      expect(mismatches).to be_empty
    end
  end

  describe "fixtures/complex_catalog.rb — Complex catalog-driven folding" do
    let(:harness) { harness_for("complex_catalog") }

    it "self-asserts the new Complex catalog coverage" do
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
    %w[parity case_when compound_writes tuple_access hash_shape block_map block_filter tuple_map].each do |name|
      it "produces no assert_type mismatches in fixtures/#{name}.rb" do
        harness = harness_for(name)
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end
  end
end
