# frozen_string_literal: true

require "spec_helper"

# `call.argument-type-mismatch` fires on a pure-`nil` argument that the
# parameter does not admit — decided on the RBS parameter type so it sees
# through both gaps the rule used to have:
#   * Gap A — multi-overload methods (the rule bailed on `method_types.size
#     != 1`), so `5 * nil` (Integer#* has four overloads) stayed silent.
#   * Gap B — interface-alias params (`string` = `String | _ToStr`,
#     `int` = `Integer | _ToInt`), which the translator degrades to gradual,
#     so `"a" + nil` stayed silent.
# Restricted to `nil` (which never participates in `coerce`) and conservative
# everywhere else. Surfaced by the tool/mutation teeth sweep over CRuby's
# `lib/` (the String / Integer nil_inject clusters).
RSpec.describe "nil argument-type-mismatch" do
  def diagnostics_for(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
  end

  def arg_mismatches(source)
    diagnostics_for(source).select { |d| d.rule == "call.argument-type-mismatch" }.map(&:message)
  end

  it "fires on a single-overload interface-alias param that rejects nil (Gap B)" do
    # "a" + nil and "a".include?(nil) raise TypeError; String#+/#include? take `string` (String | _ToStr), and nil
    # implements neither.
    expect(arg_mismatches(%(s = "a"\ns + nil\n))).to include(a_string_matching(/`\+' on String.*got nil/))
    expect(arg_mismatches(%(s = "a"\ns.include?(nil)\n)))
      .to include(a_string_matching(/`include\?' on String.*got nil/))
  end

  it "fires when nil is rejected by every overload of a multi-overload method (Gap A)" do
    # 5 * nil: none of Integer#* (Float | Rational | Complex | Integer) admits nil.
    expect(arg_mismatches("x = 5\nx * nil\n")).to include(a_string_matching(/`\*' on Integer.*got nil/))
    # Array#fetch is multi-overload with an interface-alias `int` param.
    expect(arg_mismatches("a = [1, 2, 3]\na.fetch(nil)\n")).to include(a_string_matching(/`fetch' on Array.*got nil/))
    # MatchData#[] has a `range[int?]` GENERIC-alias overload; resolving it (not bailing to "admits") lets every
    # overload reject nil so `m[nil]` fires.
    expect(arg_mismatches(%(m = "abc".match(/b/)\nunless m.nil?\n  m[nil]\nend\n)))
      .to include(a_string_matching(/`\[\]' on MatchData.*got nil/))
  end

  it "stays clean when the param admits nil" do
    # String#split's pattern is `Regexp | string | nil`.
    expect(arg_mismatches(%(s = "a b"\ns.split(nil)\n))).to be_empty
  end

  it "stays clean when an overload accepts the (non-nil) argument" do
    expect(arg_mismatches("x = 5\nx + 2.0\nx * 3\n")).to be_empty
    expect(arg_mismatches(%(s = "a"\ns + "b"\n))).to be_empty
  end

  it "does not fire on a non-nil mismatched argument (nil-only restriction — coerce-safety)" do
    # 5 * "x" raises too, but a non-nil receiver may be valid via `coerce`, so the rule is deliberately restricted to
    # nil.
    expect(arg_mismatches(%(x = 5\nx * "y"\n))).to be_empty
  end

  it "leaves valid real code clean" do
    expect(diagnostics_for(%(x = 5\ny = x * 2\nz = "a" + "b"\nz.include?("a")\n)).select(&:error?)).to be_empty
  end
end
