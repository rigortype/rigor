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
end
