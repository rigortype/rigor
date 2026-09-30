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
    expect(chain_of(scope, "M").skip_count).to eq(1)
    expect(chain_of(scope, "A").skip_count).to eq(1)
    expect(chain_of(scope, "B").skip_count).to eq(1)
    expect(names(ResolutionChainRetro.build(scope, "B"))).to include(["N", :instance])
  end

  # Every skip counts, wherever it happened: a class that draws on two modules each holding one skip has two,
  # whether the modules' chains were built first (and memoised) or as part of the class's own. A reader that
  # settles on "was anything skipped" would read one world where the tables permit several.
  it "sums skips across memoised module sub-chains" do
    source = <<~RUBY
      module N; def foo = 1; end
      module Z; include N; end
      module X; include N; include Z; end
      module Y; include N; include Z; end
      class Own; include X; include Y; end
      class Cold; include X; include Y; end
    RUBY
    scope = scope_for(source)
    expect(chain_of(scope, "X").skip_count).to eq(1)
    expect(chain_of(scope, "Y").skip_count).to eq(1)
    # X and Y are memoised now; `Y` also finds `N` and `Z` already there, which is a third skip of its own.
    expect(chain_of(scope, "Own").skip_count).to be >= 2
    cold = scope_for(source)
    expect(chain_of(cold, "Cold").skip_count).to eq(chain_of(scope, "Own").skip_count)
  end

  it "settles a chain with two or more skips to master without building a retro world" do
    scope = scope_for(<<~RUBY)
      module N
      end

      module Z
        include N
      end

      module X
        include N
        include Z
      end

      class Own
        include N
        include Z
        include X
      end
    RUBY
    chain = chain_of(scope, "Own")
    expect(chain.skip_count).to be >= 2
    expect(chain.settle(:answer) { raise "the retro world must not be read" }).to eq(:master)
    expect(chain.instance_variable_get(:@retro)).to be_nil
  end

  it "settles a skip-free chain to itself without reading the retro world" do
    scope = scope_for("module M; end\nclass C; include M; end")
    expect(chain_of(scope, "C").settle(:answer) { raise "no retro world exists" }).to eq(:chain)
  end

  it "keeps the retro world and the skip counter off its public surface" do
    scope = scope_for("module M; end\nclass C; include M; end")
    chain = chain_of(scope, "C")
    expect(chain).not_to respond_to(:retro)
    expect(chain).not_to respond_to(:contested?)
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
