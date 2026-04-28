# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::Acceptance do
  # The acceptance dispatch matrix needs many short-lived type carriers,
  # but they are all immutable flyweights or simple structural objects.
  # Using `let` for each would trip RSpec/MultipleMemoizedHelpers, so we
  # expose them as plain helper methods on the example group. The thin
  # value objects make any per-call construction cost negligible.
  def top = Rigor::Type::Combinator.top
  def bot = Rigor::Type::Combinator.bot
  def dyn_top = Rigor::Type::Combinator.untyped
  def int_nominal = Rigor::Type::Combinator.nominal_of(Integer)
  def str_nominal = Rigor::Type::Combinator.nominal_of(String)
  def numeric_nominal = Rigor::Type::Combinator.nominal_of(Numeric)
  def int_singleton = Rigor::Type::Combinator.singleton_of(Integer)
  def str_singleton = Rigor::Type::Combinator.singleton_of(String)
  def int_constant = Rigor::Type::Combinator.constant_of(1)
  def str_constant = Rigor::Type::Combinator.constant_of("hi")

  def int_or_str
    Rigor::Type::Combinator.union(int_nominal, str_nominal)
  end

  def accepts(self_type, other_type, mode: :gradual)
    described_class.accepts(self_type, other_type, mode: mode)
  end

  describe "Top" do
    it "accepts every other type" do
      [bot, dyn_top, int_nominal, int_singleton, int_constant, int_or_str].each do |other|
        expect(accepts(top, other)).to be_yes
      end
    end
  end

  describe "Bot" do
    it "accepts only Bot" do
      expect(accepts(bot, bot)).to be_yes
      expect(accepts(bot, int_nominal)).to be_no
    end
  end

  describe "Dynamic[T] in gradual mode" do
    it "accepts every concrete type" do
      [int_nominal, int_singleton, int_constant, int_or_str, top].each do |other|
        expect(accepts(dyn_top, other)).to be_yes
      end
    end
  end

  describe "Nominal" do
    it "accepts the exact same nominal" do
      expect(accepts(int_nominal, int_nominal)).to be_yes
    end

    it "accepts a subclass via Ruby hierarchy" do
      # Integer < Numeric
      expect(accepts(numeric_nominal, int_nominal)).to be_yes
    end

    it "rejects an unrelated nominal" do
      expect(accepts(int_nominal, str_nominal)).to be_no
    end

    it "accepts a Constant whose value is_a?(class)" do
      expect(accepts(int_nominal, int_constant)).to be_yes
      expect(accepts(numeric_nominal, int_constant)).to be_yes
    end

    it "rejects a Constant whose value is not_a?(class)" do
      expect(accepts(str_nominal, int_constant)).to be_no
    end

    it "rejects a Singleton" do
      expect(accepts(int_nominal, int_singleton)).to be_no
    end

    it "is maybe when the class name does not resolve to a Ruby class" do
      unresolved = Rigor::Type::Combinator.nominal_of("Definitely::Not::A::Real::Class")
      expect(accepts(unresolved, int_nominal)).to be_maybe
    end
  end

  describe "Singleton" do
    it "accepts the same singleton" do
      expect(accepts(int_singleton, int_singleton)).to be_yes
    end

    it "accepts a singleton of a subclass via Ruby hierarchy" do
      numeric_singleton = Rigor::Type::Combinator.singleton_of(Numeric)
      expect(accepts(numeric_singleton, int_singleton)).to be_yes
    end

    it "rejects a singleton of an unrelated class" do
      expect(accepts(int_singleton, str_singleton)).to be_no
    end

    it "rejects a Nominal (different value kind)" do
      expect(accepts(int_singleton, int_nominal)).to be_no
    end

    it "rejects a Constant" do
      expect(accepts(int_singleton, int_constant)).to be_no
    end
  end

  describe "Constant" do
    it "accepts only structurally equal constants" do
      expect(accepts(int_constant, Rigor::Type::Combinator.constant_of(1))).to be_yes
    end

    it "rejects different values" do
      expect(accepts(int_constant, Rigor::Type::Combinator.constant_of(2))).to be_no
    end

    it "rejects different value classes" do
      expect(accepts(int_constant, Rigor::Type::Combinator.constant_of(1.0))).to be_no
    end

    it "rejects a Nominal carrier" do
      expect(accepts(int_constant, int_nominal)).to be_no
    end
  end

  describe "Union" do
    it "accepts when at least one member accepts" do
      expect(accepts(int_or_str, int_constant)).to be_yes
      expect(accepts(int_or_str, str_constant)).to be_yes
    end

    it "rejects when no member accepts" do
      sym_constant = Rigor::Type::Combinator.constant_of(:foo)
      expect(accepts(int_or_str, sym_constant)).to be_no
    end

    it "is maybe when no member proves yes but some member is maybe" do
      unresolved = Rigor::Type::Combinator.nominal_of("Definitely::Not::A::Real::Class")
      union = Rigor::Type::Combinator.union(unresolved, str_nominal)
      expect(accepts(union, int_nominal)).to be_maybe
    end

    it "self.accepts(Union[A,B]) requires every member to be accepted" do
      union = Rigor::Type::Combinator.union(int_nominal, str_nominal)
      expect(accepts(top, union)).to be_yes
      expect(accepts(int_nominal, union)).to be_no
    end
  end

  describe "Bot/Dynamic short-circuits" do
    it "always accepts Bot regardless of self" do
      [int_nominal, str_nominal, int_constant, int_or_str].each do |self_type|
        expect(accepts(self_type, bot)).to be_yes
      end
    end

    it "accepts a Dynamic argument under gradual mode regardless of self" do
      [int_nominal, str_singleton, int_constant, int_or_str].each do |self_type|
        expect(accepts(self_type, dyn_top)).to be_yes
      end
    end
  end

  describe "modes" do
    it "raises ArgumentError for unsupported modes" do
      expect { accepts(int_nominal, int_constant, mode: :strict) }
        .to raise_error(ArgumentError, /not implemented/)
    end
  end

  describe "Type#accepts public surface" do
    it "every type form exposes accepts as a public method" do
      [top, bot, dyn_top, int_nominal, int_singleton, int_constant, int_or_str].each do |t|
        expect(t).to respond_to(:accepts)
        result = t.accepts(int_constant)
        expect(result).to be_a(Rigor::Type::AcceptsResult)
      end
    end

    it "delegates to Acceptance.accepts with the same mode" do
      result = int_nominal.accepts(int_constant)
      expect(result).to be_yes
      expect(result.mode).to eq(:gradual)
    end
  end
end
