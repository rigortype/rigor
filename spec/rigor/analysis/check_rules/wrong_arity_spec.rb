# frozen_string_literal: true

require "spec_helper"

# `call.wrong-arity` family — check_rules.rb ~L1084-1232 (`wrong_arity_diagnostic`,
# `anonymous_struct_new_call?`, `plain_positional_call?`, `simple_positional?`,
# `compute_arity_envelope`, `arity_eligible?`) plus the `build_arity_diagnostic` builder (~L2510). Fires
# when an explicit-receiver call's positional argument count falls outside the RBS-declared arity
# envelope of the resolved method.
#
# First spec for this family (#135 checkbox-1 wave 1). Mutation recon measured 5 de-noised survivors from
# 7 biteable sites; 4 of them — L1151/L1153/L1154/L1157, the whole body of `anonymous_struct_new_call?` —
# were entirely unobserved: no existing example anywhere in the suite drove an arity check through a
# chained `Struct.new(...).new` call. The 5th, `build_arity_diagnostic`'s `from_message_loc` (L2514), was
# unobserved too.
RSpec.describe "wrong arity" do
  def diagnostics_for(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
  end

  def arity_diagnostics(source)
    diagnostics_for(source).select { |d| d.rule == "call.wrong-arity" }
  end

  describe "wrong_arity_diagnostic (entry point)" do
    it "fires on a call whose positional count exceeds the RBS envelope" do
      diags = arity_diagnostics("[1].rotate(1, 2)\n")
      expect(diags.size).to eq(1)

      diagnostic = diags.first
      expect(diagnostic.rule).to eq("call.wrong-arity")
      expect(diagnostic.severity).to eq(:error)
      expect(diagnostic.error?).to be(true)
      expect(diagnostic.receiver_type).to eq("Array")
      expect(diagnostic.method_name).to eq("rotate")
      expect(diagnostic.line).to eq(1)
      expect(diagnostic.column).to eq(5) # points at `rotate`, not the `[1]` receiver
      expect(diagnostic.message).to eq("wrong number of arguments to `rotate' on Array (given 2, expected 0..1)")
    end

    it "declines when the positional count is within the envelope (adjacent to the firing case above)" do
      expect(arity_diagnostics("[1].rotate(1)\n")).to be_empty
    end
  end

  describe "build_arity_diagnostic message shape" do
    # Mutation survivor L2514 — the `Diagnostic.from_message_loc` call inside the builder. These two
    # examples pin both arms of `range = min == max ? min.to_s : "#{min}..#{max}"`: a mutant that always
    # renders the ranged form (or always the bare number) goes wrong on one of the two messages below.
    it "renders a bare number when min == max (String#+ takes exactly one positional)" do
      diags = arity_diagnostics(%("a".+()\n))
      expect(diags.size).to eq(1)
      expect(diags.first.message).to eq("wrong number of arguments to `+' on String (given 0, expected 1)")
    end

    it "declines when the exact arity is satisfied (adjacent to the firing case above)" do
      expect(arity_diagnostics(%("a".+("b")\n))).to be_empty
    end

    it "renders a min..max range when min != max (Array#rotate takes zero or one)" do
      diags = arity_diagnostics("[1].rotate(1, 2)\n")
      expect(diags.first.message).to include("expected 0..1")
    end
  end

  describe "plain_positional_call? / simple_positional? (call-site shape gating)" do
    it "fires on a plain positional call (baseline, adjacent to the declines below)" do
      expect(arity_diagnostics("[1].rotate(1, 2)\n")).not_to be_empty
    end

    it "declines a splat argument — SplatNode disqualifies plain_positional_call?" do
      # `args` carries 2 elements, a real arity mismatch at runtime too — this pins that the decline is
      # structural (the splat's element count isn't known statically), not a lucky count match.
      expect(arity_diagnostics("args = [1, 2]\n[1].rotate(*args)\n")).to be_empty
    end

    it "declines a keyword-argument call — KeywordHashNode disqualifies plain_positional_call?" do
      expect(arity_diagnostics("[1].rotate(count: 2)\n")).to be_empty
    end

    it "declines a block-pass argument — BlockArgumentNode disqualifies plain_positional_call?" do
      expect(arity_diagnostics("blk = proc {}\n[1].rotate(&blk)\n")).to be_empty
    end

    it "declines a `...` forwarding call — ForwardingArgumentsNode disqualifies plain_positional_call?" do
      source = <<~RUBY
        def wrapper(...)
          [1].rotate(...)
        end
        wrapper(1, 2)
      RUBY
      expect(arity_diagnostics(source)).to be_empty
    end
  end

  describe "compute_arity_envelope / arity_eligible?" do
    it "fires against a finite optional-positional envelope (baseline, adjacent to the declines below)" do
      expect(arity_diagnostics("[1].rotate(1, 2)\n")).not_to be_empty
    end

    it "declines any positional count once an overload has rest positionals (max raised to Infinity)" do
      # Array#push is `(*E objects) -> self` — a rest positional raises `max` to Float::INFINITY, so no
      # actual count can ever fall outside `[0, Infinity]`. Five arguments overflows `rotate`'s `[0, 1]`
      # envelope above; push must stay silent regardless of how many are given.
      expect(arity_diagnostics("[1].push(1, 2, 3, 4, 5)\n")).to be_empty
    end

    it "declines a method whose only overload has required keywords (arity_eligible? bails the method)" do
      # NoMatchingPatternKeyError#initialize is `(?string message, matchee: M, key: K) -> void` — required
      # keywords make `arity_eligible?` return false, so `compute_arity_envelope` returns nil for the whole
      # method and this (badly wrong, 4-positional) call is never checked.
      expect(arity_diagnostics("NoMatchingPatternKeyError.new(1, 2, 3, 4)\n")).to be_empty
    end
  end

  describe "anonymous_struct_new_call? (the Struct.new(...).new chain)" do
    it "fires on a bare Struct.new() — the class-defining call needs at least one positional" do
      # Baseline: with no inner `.new` chain, `anonymous_struct_new_call?` never triggers — its
      # `receiver.is_a?(Prism::CallNode) && receiver.name == :new` guard (L1151) is false because the
      # receiver here is a bare ConstantReadNode. So the real `Struct.new` envelope `[1, Infinity]` applies,
      # and 0 args is a genuine wrong-arity firing. Pairs with the chained decline below, same zero-arg
      # count, opposite verdict.
      diags = arity_diagnostics("Struct.new()\n")
      expect(diags.size).to eq(1)
      expected_message = "wrong number of arguments to `new' on Struct (given 0, expected 1..Infinity)"
      expect(diags.first.message).to eq(expected_message)
    end

    it "declines Struct.new(:a, :b).new() with zero args — the chained anonymous-subclass exclusion" do
      # The mutation-recon prize: L1151/L1153/L1154/L1157 were entirely unobserved before this spec.
      # `Struct.new(:a, :b)` types as `Singleton[Struct]` (the dispatcher's `struct_new_lift`), so the outer
      # `.new` would otherwise be checked against the SAME `[1, Infinity]` envelope as the bare case above
      # and wrongly fire on 0 args — but the chained anonymous subclass's real `.new` accepts any arity
      # (every unset member defaults to nil). `anonymous_struct_new_call?` detects the `receiver.receiver`
      # (L1153) ConstantReadNode named `:Struct` (L1154) chained through a `.new` CallNode (L1151) and skips
      # the check entirely.
      expect(arity_diagnostics("Struct.new(:a, :b).new()\n")).to be_empty
    end

    it "declines Struct.new(:a, :b).new(1, 2) with a matching member count" do
      expect(arity_diagnostics("Struct.new(:a, :b).new(1, 2)\n")).to be_empty
    end

    it "declines the `::Struct.new(...).new` form — the ConstantPathNode branch (L1157)" do
      # The top-level constant-path spelling exercises the OTHER accepted receiver shape:
      # `inner.parent.nil? && inner.name == :Struct` on a Prism::ConstantPathNode, instead of the
      # ConstantReadNode branch the two examples above exercise.
      expect(arity_diagnostics("::Struct.new(:a, :b).new()\n")).to be_empty
    end
  end
end
