# frozen_string_literal: true

require "spec_helper"

# A refinement receiver (`non-negative-int` = `Type::IntegerRange`, `non-empty-string` = `Type::Refined`) IS its base
# class for method dispatch. `concrete_class_name` resolves it to the base so the call rules (undefined-method /
# wrong-arity / argument-type-mismatch) reason about it instead of bailing on "no single concrete class". Surfaced by
# the tool/mutation teeth sweep (the `non-negative-int#>=` cluster).
RSpec.describe "refined-receiver call-rule dispatch" do
  def diagnostics_for(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
  end

  def rule_messages(source, rule)
    diagnostics_for(source).select { |d| d.rule == rule }.map(&:message)
  end

  # `[…].select { }.size` is a non-negative-int of unknown value (a literal tuple's size would constant-fold instead).
  def refined_int(expr)
    <<~RUBY
      def f(x)
        n = [1, 2, 3].select { |e| e > x }.size
        #{expr}
      end
    RUBY
  end

  it "fires argument-type-mismatch on a refined-int receiver" do
    # 5 >= nil raises ArgumentError at runtime; Integer#>= expects Numeric.
    expect(rule_messages(refined_int("n >= nil"), "call.argument-type-mismatch"))
      .to include(a_string_matching(/expected Numeric, got nil/))
  end

  it "fires undefined-method on a refined-int receiver" do
    expect(rule_messages(refined_int("n.no_such_method_zzz"), "call.undefined-method"))
      .to include(a_string_matching(/undefined method `no_such_method_zzz'/))
  end

  it "stays clean on real Integer methods called on a refined-int receiver" do
    source = refined_int("n.succ\n  n >= 2\n  n.to_s")
    expect(diagnostics_for(source).select(&:error?)).to be_empty
  end

  # The non-empty / non-zero refinements are `Type::Difference` (`Array - []`, `String - ""`, `Integer - 0`), a
  # different carrier from `Type::Refined` / `Type::IntegerRange`. A difference dispatches as its base (minuend) class —
  # subtracting values never changes the method surface.
  def non_empty_array(expr)
    <<~RUBY
      def f(x)
        a = [1, 2, 3].select { |e| e > x }
        return if a.empty?
        #{expr}
      end
    RUBY
  end

  it "fires undefined-method on a non-empty-array (Difference) receiver" do
    expect(rule_messages(non_empty_array("a.no_such_zzz"), "call.undefined-method"))
      .to include(a_string_matching(/undefined method `no_such_zzz'/))
  end

  it "stays clean on real Array methods called on a non-empty-array receiver" do
    source = non_empty_array("a.first\n  a.map { |e| e + 1 }\n  a.size")
    expect(diagnostics_for(source).select(&:error?)).to be_empty
  end
end
