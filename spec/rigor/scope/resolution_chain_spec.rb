# frozen_string_literal: true

require "spec_helper"

# The chain builder's own invariants — the ones the Ruby witness (`spec/integration/resolution_chain_witness_spec.rb`)
# cannot reach because they depend on memoisation, cycles and the budget rather than on a program Ruby runs.
RSpec.describe Rigor::Scope::ResolutionChain do
  def scope_for(source)
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
  end

  def names(chain) = chain.entries.map { |entry| [entry.name || entry.raw, entry.side] }

  def chain_of(scope, name, side = :instance, flavor = :methods) = described_class.for(scope, name, side, flavor)

  # A module's chain is memoised and reused by every includer; a skip inside it makes each includer's chain
  # contested, whichever includer built the memo first.
  it "carries a memoised module's skip into every includer" do
    scope = scope_for(<<~RUBY)
      module N
        def foo = 1
      end

      module Z
        include N
      end

      module M
        include N
        include Z
      end

      class A
        include M
      end

      class B
        include M
      end
    RUBY
    expect(chain_of(scope, "M")).to be_contested
    expect(chain_of(scope, "A")).to be_contested
    expect(chain_of(scope, "B")).to be_contested
    expect(names(chain_of(scope, "B").retro)).to include(["N", :instance])
  end

  # `extend self` reaches the module's own instance chain from its singleton chain; that is not a cycle.
  it "puts a module after its own singleton on `extend self`" do
    scope = scope_for(<<~RUBY)
      module M
        extend self

        def label = :m
      end
    RUBY
    expect(names(chain_of(scope, "M", :singleton))).to eq([["M", :singleton], ["M", :instance]])
  end

  it "terminates on a superclass cycle the tables can spell" do
    scope = scope_for(<<~RUBY)
      class A < B
      end

      class B < A
      end
    RUBY
    expect(names(chain_of(scope, "A"))).to eq([["A", :instance], ["B", :instance]])
    expect(names(chain_of(scope, "B"))).to eq([["B", :instance], ["A", :instance]])
  end

  it "keeps an external ancestor at its position with its candidate spellings" do
    scope = scope_for(<<~RUBY)
      module Outer
        class C < Base
          include Comparable
        end
      end
    RUBY
    chain = chain_of(scope, "Outer::C")
    expect(chain.entries.map(&:raw)).to eq([nil, "Comparable", "Base"])
    expect(chain.entries.last.candidates).to eq(%w[Outer::Base Base])
    expect(chain.entries.last.superclass_edge).to be(true)
    expect(chain.level_classes).to eq(["Outer::C", nil])
  end

  # Past `LIMIT` project entries the chain is cut, and only the levels that end inside the cut are counted, so
  # a reader of levels never sees half a level.
  it "cuts a chain past the budget and keeps only whole levels" do
    modules = (1..(described_class::LIMIT + 5)).map { |i| "module M#{i}; def m#{i} = #{i}; end" }.join("\n")
    includes = (1..(described_class::LIMIT + 5)).map { |i| "  include M#{i}" }.join("\n")
    scope = scope_for("#{modules}\nclass Base; end\nclass C < Base\n#{includes}\nend\n")
    chain = chain_of(scope, "C")
    expect(chain).to be_truncated
    expect(chain.entries.size).to eq(described_class::LIMIT)
    expect(chain.level_count).to eq(0)
  end

  it "rejects an unknown flavor" do
    expect { chain_of(scope_for("class C; end"), "C", :instance, :typo) }.to raise_error(ArgumentError)
  end
end
