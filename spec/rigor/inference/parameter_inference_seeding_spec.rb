# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/protection_scanner"
require "rigor/scope"
require "rigor/type"

# ADR-67 WD3 consumption side — `build_method_entry_scope` seeds an undeclared parameter from the `param_inferred_types`
# table. Exercised through the protection scanner (its `Scope#type_of` path runs the method-entry seed), the same
# surface `coverage --protection` measures.
RSpec.describe "ADR-67 WD3 inferred-parameter seeding" do
  def scan(source, table)
    root = Prism.parse(source).value
    discovery = Rigor::Scope::DiscoveryIndex::EMPTY.with(param_inferred_types: table)
    scope = Rigor::Scope.empty.with_discovery(discovery)
    Rigor::Inference::ProtectionScanner.new(scope: scope).scan(root)
  end

  let(:string_type) { Rigor::Type::Nominal.new("String") }

  it "types an undeclared parameter's receiver as concrete when seeded" do
    table = { ["Processor", :process, :instance] => { item: string_type } }
    result = scan(<<~RUBY, table)
      class Processor
        def process(item)
          item.upcase
        end
      end
    RUBY
    expect(result.unprotected_count).to eq(0)
    expect(result.protected_count).to eq(1)
    # ADR-67 WD6b (issue #263) — the seeded receiver is a call-site lower bound, so `lower_bound_typed`
    # counts it as a sub-bucket WITHIN `protected_count` (still 1 above — the headline is unchanged).
    expect(result.lower_bound_typed).to eq(1)
  end

  it "leaves the parameter untyped (unprotected) with no table entry" do
    result = scan(<<~RUBY, {})
      class Processor
        def process(item)
          item.upcase
        end
      end
    RUBY
    expect(result.unprotected_count).to eq(1)
    expect(result.protected_count).to eq(0)
  end

  it "does not override an RBS-declared parameter (RBS wins)" do
    # `String#upcase` is declared, so even a (wrong) seeded Integer entry must not replace the declared parameter — the
    # binder produced a concrete (non-untyped) type, which the seed leaves untouched. Here the parameter has no RBS sig,
    # so we assert the inverse via a singleton kind mismatch: an entry keyed :singleton must not seed an :instance
    # method.
    table = { ["Processor", :process, :singleton] => { item: string_type } }
    result = scan(<<~RUBY, table)
      class Processor
        def process(item)
          item.upcase
        end
      end
    RUBY
    expect(result.unprotected_count).to eq(1)
  end

  it "seeds a singleton-method parameter under the :singleton kind" do
    table = { ["Processor", :build, :singleton] => { item: string_type } }
    result = scan(<<~RUBY, table)
      class Processor
        def self.build(item)
          item.upcase
        end
      end
    RUBY
    expect(result.unprotected_count).to eq(0)
    expect(result.protected_count).to eq(1)
  end

  # ADR-67 WD6b (issue #263) — `lower_bound_typed` split within `protected_count`.
  describe "lower_bound_typed (ADR-67 WD6b, issue #263)" do
    it "does not mark an RBS-declared parameter, even with a (misapplied) table entry for the same key" do
      # `Integer#divmod`'s parameter binds from the real Integer RBS signature (a concrete union), not the
      # untyped sentinel, so `seed_inferred_param_types` declines to override it — no WD6b mark is stamped —
      # even though the table happens to carry an entry keyed to the same `[class, method, kind]` triple.
      table = { ["Integer", :divmod, :instance] => { other: string_type } }
      result = scan(<<~RUBY, table)
        class Integer
          def divmod(other)
            other.to_s
          end
        end
      RUBY
      expect(result.protected_count).to eq(1)
      expect(result.lower_bound_typed).to eq(0)
    end

    it "reports the same protected_count/ratio for a lower-bound-typed site as for a fully-declared one " \
       "(headline invariance)" do
      # Two single-dispatch-site fixtures, one seeded (lower-bound) and one RBS-declared (not lower-bound):
      # both classify as ONE protected site with ratio 1.0 — `protected_count`/`ratio` reflect only the
      # upper-bound "is the receiver concrete" question, never whether the concrete type is a lower bound.
      # The WD6b split is purely additive information layered on top.
      seeded_table = { ["Processor", :process, :instance] => { item: string_type } }
      seeded = scan(<<~RUBY, seeded_table)
        class Processor
          def process(item)
            item.upcase
          end
        end
      RUBY
      declared = scan(<<~RUBY, {})
        class Integer
          def divmod(other)
            other.to_s
          end
        end
      RUBY

      expect(seeded.protected_count).to eq(declared.protected_count)
      expect(seeded.ratio).to eq(declared.ratio)
      expect(seeded.lower_bound_typed).to eq(1)
      expect(declared.lower_bound_typed).to eq(0)
    end
  end
end
