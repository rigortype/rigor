# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-91 WD3 — spelling-parity invariant for the Kernel intrinsic fold ownership gate.
#
# Origin: the rigor-rs port's upstream-feedback note (rigor-rs `docs/notes/20260716-upstream-feedback.md`,
# item 1) and PR #110, which fixed one instance of a bug class — `Kernel.p(42)` declined the identity fold
# while `Kernel.format("%d", 1)` folded, two spellings of the same `module_function` surface with opposite
# polarities. ADR-91 closes the class structurally: every Kernel module-function fold now runs behind a
# single dispatcher-held ownership gate keyed on
# `Rigor::Inference::MethodDispatcher::KernelDispatch::INTRINSIC_NAMES`, and this spec derives its case
# list from that SAME table — a fold added to the gate without a parity entry here fails example 1 below,
# and a fold that regresses spelling polarity fails its own per-name example.
#
# Each entry is `[template, expected]`: `template` is the literal call-argument list appended to the
# intrinsic's name (bare and `Kernel.`-qualified), `expected` is the `Type#describe(:short)` rendering the
# fold MUST produce for both spellings — pinning the fold to a precise, non-Dynamic result so parity can't
# be satisfied by both spellings degrading to `Dynamic` in lockstep.
KERNEL_INTRINSIC_PARITY_TEMPLATES = {
  Array: ["(nil)", "Array[bot]"],
  Integer: ['("42")', "42"],
  Float: ['("1.5")', "1.5"],
  Rational: ["(1, 2)", "(1/2)"],
  Complex: ["(1, 2)", "(1+2i)"],
  p: ["(42)", "42"],
  pp: ["(1, 2)", "[1, 2]"],
  String: ["(42)", '"42"'],
  Hash: ["(nil)", "{}"],
  format: ['("%d", 1)', '"1"'],
  sprintf: ['("%d", 2)', '"2"']
}.freeze

RSpec.describe "Kernel intrinsic fold spelling parity (ADR-91 WD3)" do
  # Runs a single-statement source (`x = <call>`) through the full engine and returns the post-evaluation
  # type of the top-level local `x`. Mirrors `IntegrationSupport::FixtureHarness#local`, but self-contained
  # here since this spec has no fixture file — the source is a one-liner built from the template table.
  def local_type_of(source)
    tree = Prism.parse(source).value
    scope = Rigor::Scope.empty(environment: Rigor::Environment.default)
    post_scope = scope.evaluate(tree).last
    post_scope.local(:x)
  end

  it "keeps the parity table's names exactly in sync with KernelDispatch::INTRINSIC_NAMES" do
    # Load-bearing: if a fold is added to the gate's table without a parity entry here (or vice versa), this
    # example fails loudly — the table can't silently drift from the data the dispatcher actually gates on.
    gate_names = Rigor::Inference::MethodDispatcher::KernelDispatch::INTRINSIC_NAMES.to_a.sort
    expect(KERNEL_INTRINSIC_PARITY_TEMPLATES.keys.sort).to eq(gate_names)
  end

  KERNEL_INTRINSIC_PARITY_TEMPLATES.each do |name, (args, expected)|
    describe "Kernel##{name}" do
      let(:implicit_source) { "x = #{name}#{args}" }
      let(:explicit_source) { "x = Kernel.#{name}#{args}" }

      it "folds the implicit-self spelling to the expected precise type" do
        expect(local_type_of(implicit_source).describe(:short)).to eq(expected)
      end

      it "folds the explicit Kernel. spelling to the expected precise type" do
        expect(local_type_of(explicit_source).describe(:short)).to eq(expected)
      end

      it "infers an IDENTICAL type for both spellings" do
        implicit_type = local_type_of(implicit_source)
        explicit_type = local_type_of(explicit_source)

        expect(implicit_type.describe(:short)).to eq(explicit_type.describe(:short))
        expect(implicit_type).to eq(explicit_type)
      end
    end
  end
end
