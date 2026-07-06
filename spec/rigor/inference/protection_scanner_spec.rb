# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/protection_scanner"
require "rigor/scope"

# ADR-63 Tier 1 — the static type-protection proxy: a dispatch site is protected when its receiver types concrete
# (Rigor's call rules can bite), unprotected when the receiver is Dynamic.
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
    # An undeclared parameter routes to parameter inference (ADR-82 root-enrichment).
    expect(result.sites.first.dynamic_origin).to eq(:inferred_return_untyped)
  end

  it "routes an undeclared parameter's chain to parameter inference (ADR-82 root-enrichment)" do
    # `x` is an untyped parameter — the archetypal ADR-67 inference gap — so `x.foo` and, via WD6 chain
    # inheritance, `x.foo.bar` route to `inferred_return_untyped` instead of reporting no cause.
    result = scan(<<~RUBY)
      def f(x)
        x.foo.bar
      end
    RUBY
    chain = result.sites.select { |s| %w[foo bar].include?(s.method_name) }
    expect(chain.size).to eq(2)
    expect(chain.map(&:dynamic_origin)).to all(eq(:inferred_return_untyped))
  end

  it "propagates a local binding's origin to a later bare-receiver read (ADR-82 WD1)" do
    # `y` binds to the (dynamic) result of a resolved user method, so its own read node carries no
    # origin — the cause was recorded on the assignment's rhs. WD1 follows the binding, so `y.save`'s
    # receiver resolves to that propagated cause instead of a bare nil.
    result = scan(<<~RUBY)
      class C
        def helper; end

        def f
          y = helper
          y.save
        end
      end
    RUBY
    save_site = result.sites.find { |s| s.method_name == "save" }
    expect(save_site).not_to be_nil
    expect(save_site.dynamic_origin).not_to be_nil
  end

  it "carries a dynamic receiver's origin across a method chain (ADR-82 WD6)" do
    # Each hop of `y.foo.bar.baz` dispatches on a Dynamic receiver; without WD6 only `foo`'s receiver
    # (`y`) resolves a cause and the later hops look causeless. WD6 inherits the receiver's origin onto
    # the call it produces, so every hop reports the same propagated cause.
    result = scan(<<~RUBY)
      class C
        def helper; end

        def f
          y = helper
          y.foo.bar.baz
        end
      end
    RUBY
    chain = result.sites.select { |s| %w[foo bar baz].include?(s.method_name) }
    expect(chain.size).to eq(3)
    expect(chain.map(&:dynamic_origin)).to all(be_truthy)
    expect(chain.map(&:dynamic_origin).uniq.size).to eq(1)
  end

  it "carries dynamic_origin when the scope seeds it for the receiver" do
    source = <<~RUBY
      def f(x)
        x.save
      end
    RUBY
    root = Prism.parse(source).value
    scope = Rigor::Scope.empty

    receiver_node = nil
    Rigor::Source::NodeWalker.each(root) do |node|
      if node.is_a?(Prism::CallNode) && node.receiver
        receiver_node = node.receiver
        break
      end
    end
    scope.record_dynamic_origin(receiver_node, :unsupported_syntax) if receiver_node

    result = described_class.new(scope: scope).scan(root)
    expect(result.unprotected_count).to eq(1)
    expect(result.sites.first.dynamic_origin).to eq(:unsupported_syntax)
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
