# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/protection_scanner"
require "rigor/scope"

# ADR-63 Tier 1 — the static type-protection proxy: a dispatch site is
# protected when its receiver types concrete (Rigor's call rules can bite),
# unprotected when the receiver is Dynamic.
RSpec.describe Rigor::Inference::ProtectionScanner do
  def scan(source)
    root = Prism.parse(source).value
    described_class.new(scope: Rigor::Scope.empty).scan(root)
  end

  it "counts a call on a concrete receiver as protected" do
    result = scan(%("hello".upcase\n))
    expect(result.protected_count).to eq(1)
    expect(result.unprotected_count).to eq(0)
    expect(result.ratio).to eq(1.0)
  end

  it "counts a call on an untyped receiver as unprotected and records the site" do
    result = scan(<<~RUBY)
      def f(x)
        x.save
      end
    RUBY
    expect(result.unprotected_count).to eq(1)
    expect(result.protected_count).to eq(0)
    expect(result.sites.first.method_name).to eq("save")
  end

  it "treats a union with a Dynamic arm as unprotected (gradually valid)" do
    result = scan(<<~RUBY)
      def f(flag, x)
        y = flag ? "s" : x
        y.upcase
      end
    RUBY
    expect(result.unprotected_count).to eq(1)
  end

  it "excludes receiver-less (implicit-self) calls — no receiver to score" do
    result = scan(<<~RUBY)
      def f
        helper
      end
    RUBY
    expect(result.total).to eq(0)
  end

  it "scores each call in a chain by its own receiver" do
    # "x".upcase -> String (protected); (…).foo -> the String result is concrete
    result = scan(%("x".upcase.length\n))
    expect(result.protected_count).to eq(2)
    expect(result.unprotected_count).to eq(0)
  end

  describe "safe_describe (private)" do
    let(:scanner) { described_class.new(scope: Rigor::Scope.empty) }

    it "uses #describe(:short) for a type that responds to it" do
      nominal = Rigor::Type::Combinator.nominal_of("String")
      expect(scanner.send(:safe_describe, nominal)).to eq(nominal.describe(:short))
    end

    it "falls back to #to_s for an object without #describe" do
      obj = Object.new
      expect(scanner.send(:safe_describe, obj)).to eq(obj.to_s)
    end

    it "falls back to the class name when #describe raises" do
      bad = Object.new
      def bad.describe(_level) = raise("boom")
      expect(scanner.send(:safe_describe, bad)).to eq("Object")
    end
  end
end
