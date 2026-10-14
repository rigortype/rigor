# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::UntypedRejoin do
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:string) { Rigor::Type::Combinator.nominal_of("String") }
  let(:nil_type) { Rigor::Type::Combinator.constant_of(nil) }
  let(:narrowed) { Rigor::Type::Combinator.union(untyped, string, nil_type) }
  let(:entry) { Rigor::Scope.empty.with_local(:x, untyped) }
  let(:joined) { Rigor::Scope.empty.with_local(:x, narrowed) }

  def arms(source) = [Prism.parse(source).value]

  it "binds a local the arms only narrowed back to Dynamic[top]" do
    expect(described_class.apply(joined, entry, arms("puts x")).local(:x)).to eq(untyped)
  end

  it "keeps the join for a local an arm writes, a pattern capture included" do
    ["x = nil", "x ||= 1", "a, x = 1, 2", "case 1 in Integer => x then 1 end"].each do |source|
      expect(described_class.apply(joined, entry, arms(source)).local(:x)).to eq(narrowed), source
    end
  end

  it "keeps the join when the entry binding is not Dynamic[top]" do
    faceted = Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.union(string, nil_type))
    [faceted, Rigor::Type::Combinator.union(untyped, nil_type)].each do |entry_type|
      scope = Rigor::Scope.empty.with_local(:x, entry_type)
      expect(described_class.apply(joined, scope, arms("puts x")).local(:x)).to eq(narrowed)
    end
  end

  it "keeps a joined union with no Dynamic member" do
    concrete = Rigor::Type::Combinator.union(string, nil_type)
    scope = Rigor::Scope.empty.with_local(:x, concrete)
    expect(described_class.apply(scope, entry, arms("puts x")).local(:x)).to eq(concrete)
  end

  it "returns the joined scope itself when nothing qualifies" do
    expect(described_class.apply(entry, entry, arms("puts x"))).to equal(entry)
  end

  describe "Scope#with_rejoined_locals" do
    it "rebinds the locals without dropping what a write drops" do
      scope = Rigor::Scope.empty.with_local(:x, string).with_local_origin(:x, :marshal_load)
      rejoined = scope.with_rejoined_locals({ x: untyped })
      expect(rejoined.local(:x)).to eq(untyped)
      expect(rejoined.local_origin(:x)).to eq(:marshal_load)
      expect(scope.with_local(:x, untyped).local_origin(:x)).to be_nil
    end
  end
end
