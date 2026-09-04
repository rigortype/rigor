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

  # ADR-82 WD9 — an unresolved constant owned by a locked, RBS-less gem labels its chain `add_rbs`-tractable.
  it "routes a chain rooted at an RBS-less locked gem's constant to `external_gem_without_rbs`" do
    allow(Rigor::Environment::MissingGemConstantIndex).to receive(:build)
      .and_return({ "Faraday" => "faraday" })
    environment = Rigor::Environment.new(missing_rbs_gems: [["faraday", "2.0.0"]])
    root = Prism.parse("Faraday.new.get(\"/\")\n").value
    result = described_class.new(scope: Rigor::Scope.empty(environment: environment)).scan(root)

    chain = result.sites.select { |s| %w[new get].include?(s.method_name) }
    expect(chain.size).to eq(2)
    expect(chain.map(&:dynamic_origin)).to all(eq(:external_gem_without_rbs))
  end

  # A constant no gem owns (a typo, an unanalyzed project path) keeps the generic cause — the fail-open
  # direction is a missing label, never a wrong one.
  it "keeps the generic cause for an unresolved constant no locked gem declares" do
    allow(Rigor::Environment::MissingGemConstantIndex).to receive(:build)
      .and_return({ "Faraday" => "faraday" })
    environment = Rigor::Environment.new(missing_rbs_gems: [["faraday", "2.0.0"]])
    root = Prism.parse("Farraday.new\n").value
    result = described_class.new(scope: Rigor::Scope.empty(environment: environment)).scan(root)

    site = result.sites.find { |s| s.method_name == "new" }
    expect(site.dynamic_origin).to eq(:unsupported_syntax)
  end

  it "counts a call on a concrete receiver as protected" do
    result = scan(%("hello".upcase\n))
    expect(result.protected_count).to eq(1)
    expect(result.unprotected_count).to eq(0)
    expect(result.ratio).to eq(1.0)
    # ADR-67 WD6b (issue #263) — a literal receiver is not rooted at an inferred parameter, so it is never
    # lower-bound-typed. This is the headline-invariance regression: the same protected_count/ratio as
    # before the WD6b split, since a literal receiver was never eligible for the split.
    expect(result.lower_bound_typed).to eq(0)
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

  # Issue #522 — a call the dispatch tiers exhausted still names a PROJECT method: the discovered tier
  # declined in favor of body inference (a def source exists) and inference declined on the parameter
  # shape. The honest cause is the inference gap, not "unsupported syntax" — on mastodon every
  # service-object `#call` carried the wrong label.
  it "routes a chain behind an unresolved call with a discovered project def to inferred_return_untyped" do
    # `call`'s own receiver is concrete (protected — not a site); the label shows on the DOWNSTREAM
    # dispatch whose Dynamic receiver inherits the call node's provenance via ADR-82 WD6. The def uses a
    # trailing post parameter — the one shape the #524 per-parameter binder still declines — so the
    # fixture keeps exercising the decline path on the integrated tree too.
    result = scan(<<~RUBY)
      class Service
        def call(first, *rest, last)
          rest
        end
      end

      Service.new.call(1, 2, 3).foo
    RUBY
    site = result.sites.find { |s| s.method_name == "foo" }
    expect(site).not_to be_nil
    expect(site.dynamic_origin).to eq(:inferred_return_untyped)
  end

  # The generic cause stays for a name no scanned file defines — the discriminating control for the
  # relabel above.
  it "keeps the generic cause behind an unresolved call with no discovered project def" do
    result = scan(<<~RUBY)
      class Service
      end

      Service.new.frobnicate(1).foo
    RUBY
    site = result.sites.find { |s| s.method_name == "foo" }
    expect(site).not_to be_nil
    expect(site.dynamic_origin).to eq(:unsupported_syntax)
  end

  it "routes an unbound instance-variable's chain to inference (ADR-82 root-enrichment)" do
    # `@x` is not assigned in this scope — the engine does not track the field's type (an ADR-58 gap) —
    # so `@x.foo` and, via WD6, `@x.foo.bar` route to `inferred_return_untyped` instead of no cause.
    result = scan(<<~RUBY)
      def f
        @x.foo.bar
      end
    RUBY
    chain = result.sites.select { |s| %w[foo bar].include?(s.method_name) }
    expect(chain.size).to eq(2)
    expect(chain.map(&:dynamic_origin)).to all(eq(:inferred_return_untyped))
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
    expect(result.lower_bound_typed).to eq(0)
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

# Issue #530 item 1 — the superclass reach.
#
# WD9's tagging keys on CONSTANT READS, so it labels `Parser::AST::Node` where the name is WRITTEN (the
# superclass position) and nothing after it. Every implicit-self call INHERITED into a subclass body then
# recorded the generic `unsupported_syntax` cause, so a target whose base class lives in an RBS-less gem
# reported almost all of its holes as engine gaps. Measured on rubocop-ast: 687 engine-gap / 13 add-rbs
# before, 527 / 173 after, with diagnostics byte-identical.
#
# The walk this exercises reads `discovered_superclasses`, which `ProtectionScanner#scan` builds from the
# source it is given — so the fixture below has to DECLARE the intermediate class, not just name it.
RSpec.describe Rigor::Inference::ProtectionScanner, "external-gem ancestry (#530)" do
  # `#scan` indexes the tree itself, so the discovered-superclass table this walk reads is built from the
  # source below rather than seeded here.
  def scan_indexed(source, environment:)
    root = Prism.parse(source).value
    described_class.new(scope: Rigor::Scope.empty(environment: environment)).scan(root)
  end

  let(:environment) do
    allow(Rigor::Environment::MissingGemConstantIndex).to receive(:build).and_return({ "Parser" => "parser" })
    Rigor::Environment.new(missing_rbs_gems: [["parser", "3.3.0"]])
  end

  # `node_parts` is defined by neither class — it is inherited from the gem's `Parser::AST::Node`. The
  # scanner records sites by RECEIVER, so the assertion is on the chained call whose receiver is that
  # inherited result: `node_parts[1]` is the shape that dominates rubocop-ast (125 `#[]` sites).
  let(:source) do
    <<~RUBY
      module Demo
        class Node < Parser::AST::Node
        end

        class AliasNode < Node
          def old_identifier
            node_parts.first
          end
        end
      end
    RUBY
  end

  it "attributes an inherited implicit-self call to the RBS-less gem the ancestry reaches" do
    result = scan_indexed(source, environment: environment)
    site = result.sites.find { |s| s.method_name == "first" }
    expect(site).not_to be_nil
    expect(site.dynamic_origin).to eq(:external_gem_without_rbs)
  end

  it "keeps the generic cause when the ancestry stays inside the project" do
    # The must-still-decline arm: a base class the project itself declares reaches no gem, so nothing
    # should be relabelled. Without this, a change that returned the gem cause unconditionally would pass
    # the example above.
    local = <<~RUBY
      module Demo
        class Base
        end

        class Child < Base
          def probe
            node_parts.first
          end
        end
      end
    RUBY
    result = scan_indexed(local, environment: environment)
    site = result.sites.find { |s| s.method_name == "first" }
    expect(site).not_to be_nil
    expect(site.dynamic_origin).to eq(:unsupported_syntax)
  end
end
