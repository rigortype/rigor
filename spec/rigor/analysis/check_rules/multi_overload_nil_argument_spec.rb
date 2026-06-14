# frozen_string_literal: true

require "spec_helper"

# `call.argument-type-mismatch` now fires on a MULTI-overload method when a
# pure-`nil` argument is rejected by EVERY overload's matching positional
# param. The single-overload rule already caught a plain-param nil
# (`def f: (String) -> void` called with nil); this extends it to overloaded
# core methods (`Integer#*` has 4 overloads) for the FP-safe nil channel
# only — `nil` never coerces, so a `nil` no overload accepts is a guaranteed
# `TypeError`, unlike a non-nil arg a numeric overload "rejects" that may be
# valid via `coerce`. Surfaced by the tool/mutation teeth sweep over
# CRuby's `lib/` (the `Integer#*/-/%` nil_inject cluster).
RSpec.describe "multi-overload nil argument-type-mismatch" do
  def diagnostics_for(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
  end

  def arg_mismatches(source)
    diagnostics_for(source).select { |d| d.rule == "call.argument-type-mismatch" }.map(&:message)
  end

  it "fires when nil is rejected by every overload of a multi-overload operator" do
    # 5 * nil raises TypeError (nil can't be coerced into Integer); none of
    # Integer#* (Float | Rational | Complex | Integer) admits nil.
    expect(arg_mismatches("x = 5\nx * nil\n")).to include(a_string_matching(/`\*' on Integer.*got nil/))
    expect(arg_mismatches("x = 5\nx - nil\n")).to include(a_string_matching(/`-' on Integer.*got nil/))
    expect(arg_mismatches("x = 5\nx % nil\n")).to include(a_string_matching(/`%' on Integer.*got nil/))
  end

  it "stays clean when an overload accepts the (non-nil) argument" do
    # 5 + 2.0 selects the Float overload; 5 * 3 the Integer overload.
    expect(arg_mismatches("x = 5\nx + 2.0\nx * 3\n")).to be_empty
  end

  it "does not fire on a non-nil mismatched argument (nil-only restriction — coerce-safety)" do
    # 5 * "x" raises at runtime too, but a non-nil receiver may be valid via
    # `coerce`, so the multi-overload slice is deliberately restricted to nil.
    expect(arg_mismatches(%(x = 5\nx * "y"\n))).to be_empty
  end

  it "does not fire when any overload's param is a gradual interface alias" do
    # Array#fetch's `int` param is `Integer | _ToInt`; the _ToInt arm makes it
    # gradual, so the rule conservatively declines (the interface-alias case is
    # a separate, deferred follow-up — Gap B).
    expect(arg_mismatches("a = [1, 2, 3]\na.fetch(nil)\n")).to be_empty
  end

  it "leaves valid real arithmetic clean" do
    expect(diagnostics_for("x = 5\ny = x * 2\nz = y - 1\nz % 3\n").select(&:error?)).to be_empty
  end
end
