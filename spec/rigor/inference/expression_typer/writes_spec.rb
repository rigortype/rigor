# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `ExpressionTyper::Writes` types an assignment or compound write in value position: the rvalue for a
# plain write, and the value a `+=` / `||=` / `&&=` STORES for a variable, constant or index target. The examples
# call the entries with a scope that binds the target (or leaves it unbound, the memoisation idiom) and a real typer
# over it; the module reads `scope` and `tracer` and calls back `typer.type_of`, `typer.dynamic_top` and
# `typer.resolve_constant_name`.
RSpec.describe Rigor::Inference::ExpressionTyper::Writes do
  let(:combinator) { Rigor::Type::Combinator }
  let(:integer) { combinator.nominal_of("Integer") }
  let(:string) { combinator.nominal_of("String") }
  let(:scope) { Rigor::Scope.empty }

  def node_of(source) = Prism.parse(source, scopes: [%i[x r]]).value.statements.body.first

  def typer_over(over) = Rigor::Inference::ExpressionTyper.new(scope: over)

  def compound(source, over = scope)
    node = node_of(source)
    entry = node.class.name.include?("Constant") ? :type_of_compound_constant_write : :type_of_compound_variable_write
    described_class.public_send(entry, node, over, typer_over(over))
  end

  describe ".type_of_assignment_write" do
    it "types a write as the type of its rvalue" do
      bound = scope.with_local(:r, integer)

      expect(described_class.type_of_assignment_write(node_of("x = r"), typer_over(bound))).to equal(integer)
      expect(described_class.type_of_assignment_write(node_of("A = 1"), typer_over(scope)).describe).to eq("1")
    end
  end

  describe "a compound variable write" do
    it "types `+=` as the dispatched operator over the target's current binding" do
      bound = scope.with_local(:x, combinator.constant_of(1))

      expect(compound("x += 1", bound).describe).to eq("2")
    end

    it "reads the current binding of an instance, class and global variable" do
      bound = scope.with_ivar(:@a, combinator.constant_of(1)).with_cvar(:@@b, combinator.constant_of(2))
                   .with_global(:$c, combinator.constant_of(3))

      expect(compound("@a += 1", bound).describe).to eq("2")
      expect(compound("@@b += 1", bound).describe).to eq("3")
      expect(compound("$c += 1", bound).describe).to eq("4")
    end

    it "types `||=` on an unbound target as the rvalue (the memoisation idiom)" do
      expect(compound("@memo ||= 1").describe).to eq("1")
      expect(compound("x ||= 1").describe).to eq("1")
    end

    it "types `||=` on an unbound target whose rvalue has no truthy part as the rvalue joined with Dynamic[top]" do
      expect(compound("@v ||= nil").describe).to eq("Dynamic[top]?")
      expect(compound("@v ||= false").describe).to eq("Dynamic[top] | false")
    end

    it "types `||=` on a bound target as the truthy part of the binding joined with the rvalue" do
      bound = scope.with_local(:x, combinator.union(integer, combinator.constant_of(nil)))

      expect(compound('x ||= "a"', bound).describe).to eq('"a" | Integer')
    end

    it "types `&&=` as the falsey part of the binding joined with the rvalue" do
      bound = scope.with_local(:x, combinator.union(integer, combinator.constant_of(nil)))

      expect(compound("x &&= 1", bound).describe).to eq("1?")
      expect(compound("x &&= 1").describe).to eq("1 | Dynamic[top]")
    end
  end

  describe "a compound constant write" do
    it "types `||=` on a constant nothing binds as the rvalue" do
      expect(compound("MEMO ||= 1").describe).to eq("1")
    end

    it "types `||=` on a resolvable constant as the truthy part of its type joined with the rvalue" do
      expect(compound("Integer ||= 1").describe).to eq("1 | singleton(Integer)")
    end

    it "types a constant path write the same way" do
      expect(compound("Integer::MEMO ||= 1").describe).to eq("1")
    end

    it "types a path whose base names no constant as the rvalue" do
      expect(compound("x::MEMO ||= 1").describe).to eq("1")
    end
  end

  describe ".type_of_index_compound_write" do
    it "asks the statement evaluator for the value `h[k] += v` stores" do
      bound = scope.with_local(:x, combinator.hash_shape_of({ a: combinator.constant_of(1) }))
      node = node_of("x[:a] += 1")

      expect(described_class.type_of_index_compound_write(node, bound, nil).describe).to eq("2")
    end

    it "hands the tracer to the evaluator, so a fallback inside the write is recorded on it" do
      tracer = Rigor::Inference::FallbackTracer.new
      bound = scope.with_local(:x, combinator.hash_shape_of({ a: combinator.constant_of(1) }))

      described_class.type_of_index_compound_write(node_of("x[NoSuchConstant] += 1"), bound, tracer)

      expect(tracer.events.map(&:node_class)).to include(Prism::ConstantReadNode)
    end
  end

  # The constant binding's callback, `typer.resolve_constant_name(full_name, rooted: rooted, caller_derived: false)`,
  # needs the discovery tables and a lexical nesting, which `Scope.empty` lacks, so these go through the runner.
  describe "the constant binding a compound write reads", type: :runner do
    def dumped_type(source)
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      result.diagnostics.filter_map do |diagnostic|
        diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
      end.first
    end

    it "passes `rooted:`, so `::X ||=` reads the top-level constant past a lexically nearer one" do
      expect(dumped_type(<<~RUBY)).to eq("5 | 9")
        ::TOPW = 5
        module Outer
          TOPW = :inner
          Rigor.dump_type(::TOPW ||= 9)
        end
      RUBY
    end

    it "passes `caller_derived: false`, so a top-level memo is not bound to the calling namespace's constant" do
      expect(dumped_type(<<~RUBY)).to eq("{}")
        def registry = (REGISTRY ||= {})

        class Plugin
          REGISTRY = "plugins"

          def entries = Rigor.dump_type(registry)
        end
      RUBY
    end
  end
end
