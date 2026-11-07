# frozen_string_literal: true

require "spec_helper"

# `Reflection.rbs_method_defined` and `Reflection.ancestry_reaches`: the RBS-through-project-ancestry readers. A
# project class is not in RBS itself; its RBS-known ancestors are the external entries of its chain.
RSpec.describe Rigor::Reflection, "RBS ancestry readers" do
  def scope_for(source)
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
  end

  let(:scope) { scope_for("class Kid < String\nend\n") }
  let(:yes) { Rigor::Trinary.yes }
  let(:no) { Rigor::Trinary.no }
  let(:maybe) { Rigor::Trinary.maybe }

  # Longer than `ResolutionChain::LIMIT`, so the walk is cut with an ancestor still ahead.
  let(:cut_scope) do
    limit = Rigor::Scope::ResolutionChain::LIMIT
    classes = (0..(limit + 10)).map { |i| "class Chain#{i} < Chain#{i + 1}\nend\n" }.join
    scope_for("#{classes}class Chain#{limit + 11} < String\nend\n")
  end

  describe ".rbs_method_defined" do
    it "answers yes for an instance method an RBS-known superclass declares" do
      expect(described_class.rbs_method_defined("Kid", :upcase, kind: :instance, scope: scope)).to eq(yes)
    end

    it "answers no for an absent instance method" do
      expect(described_class.rbs_method_defined("Kid", :absent_thing, kind: :instance, scope: scope)).to eq(no)
    end

    it "answers yes for a singleton method an RBS-known superclass declares" do
      expect(described_class.rbs_method_defined("Kid", :try_convert, kind: :singleton, scope: scope)).to eq(yes)
    end

    it "answers no for an absent singleton method" do
      expect(described_class.rbs_method_defined("Kid", :absent_thing, kind: :singleton, scope: scope)).to eq(no)
    end

    it "answers maybe when the chain is cut before an answer" do
      expect(described_class.rbs_method_defined("Chain0", :absent_thing, kind: :instance, scope: cut_scope))
        .to eq(maybe)
    end

    it "answers no for a nil class name" do
      expect(described_class.rbs_method_defined(nil, :upcase, kind: :instance, scope: scope)).to eq(no)
    end

    it "raises ArgumentError for an unknown kind" do
      expect { described_class.rbs_method_defined("Kid", :upcase, kind: :both, scope: scope) }
        .to raise_error(ArgumentError, /unknown kind/)
    end
  end

  describe ".ancestry_reaches" do
    it "answers yes for a named ancestor, and no for one the chain does not reach" do
      expect(described_class.ancestry_reaches("Kid", ["String"], kind: :instance, scope: scope)).to eq(yes)
      expect(described_class.ancestry_reaches("Kid", ["Integer"], kind: :instance, scope: scope)).to eq(no)
    end

    it "answers for the singleton chain too" do
      expect(described_class.ancestry_reaches("Kid", ["String"], kind: :singleton, scope: scope)).to eq(yes)
      expect(described_class.ancestry_reaches("Kid", ["Integer"], kind: :singleton, scope: scope)).to eq(no)
    end

    it "ignores a leading :: on a wanted name" do
      expect(described_class.ancestry_reaches("Kid", ["::String"], kind: :instance, scope: scope)).to eq(yes)
    end

    it "answers maybe when the chain is cut before an answer" do
      expect(described_class.ancestry_reaches("Chain0", ["Integer"], kind: :instance, scope: cut_scope)).to eq(maybe)
    end

    it "answers no for a nil class name" do
      expect(described_class.ancestry_reaches(nil, ["String"], kind: :instance, scope: scope)).to eq(no)
    end

    it "raises ArgumentError for an unknown kind" do
      expect { described_class.ancestry_reaches("Kid", ["String"], kind: :both, scope: scope) }
        .to raise_error(ArgumentError, /unknown kind/)
    end
  end
end
