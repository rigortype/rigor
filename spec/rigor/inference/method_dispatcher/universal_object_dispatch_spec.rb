# frozen_string_literal: true

require "spec_helper"

# The last resolution tier for a `Dynamic` receiver. What it does NOT answer is as load-bearing as what it does —
# every exclusion below was measured on this repository's own `lib` before being made one, so each has its own
# example rather than living in a comment.
RSpec.describe Rigor::Inference::MethodDispatcher::UniversalObjectDispatch do
  def untyped = Rigor::Type::Combinator.untyped

  def bool
    Rigor::Type::Combinator.union(Rigor::Type::Combinator.constant_of(true),
                                  Rigor::Type::Combinator.constant_of(false))
  end

  def dispatch(method_name, receiver: untyped, args: [])
    described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: args))
  end

  describe "the type predicates" do
    it "answers bool for every predicate whose result is a function of the language, not the receiver" do
      %i[nil? is_a? kind_of? instance_of? respond_to? equal? frozen? !].each do |selector|
        expect(dispatch(selector)).to eq(bool), "expected #{selector} to answer bool"
      end
    end
  end

  describe "the Object contract methods" do
    it "answers String for inspect" do
      expect(dispatch(:inspect)).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "answers Integer for hash and object_id" do
      expect(dispatch(:hash)).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(dispatch(:object_id)).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end
  end

  describe "declines" do
    it "declines for a receiver the dispatcher can name, so RBS and the folders keep answering" do
      expect(dispatch(:nil?, receiver: Rigor::Type::Combinator.nominal_of("String"))).to be_nil
      expect(dispatch(:nil?, receiver: Rigor::Type::Combinator.constant_of(nil))).to be_nil
    end

    it "declines `class`: Nominal[Class] erases the singleton, and `p.class.dynamic_returns` is real code" do
      expect(dispatch(:class)).to be_nil
    end

    it "declines the `==` family: an overridden `==` is free to return anything" do
      expect(dispatch(:==, args: [untyped])).to be_nil
      expect(dispatch(:!=, args: [untyped])).to be_nil
      expect(dispatch(:eql?, args: [untyped])).to be_nil
    end

    it "declines `to_s` while the Array#[](Range) optional-return noise it exposes has no answer" do
      expect(dispatch(:to_s)).to be_nil
    end

    it "declines the self-returners, which gain nothing on a Dynamic receiver" do
      %i[freeze dup clone itself tap].each { |selector| expect(dispatch(selector)).to be_nil }
    end

    it "declines an ordinary selector" do
      expect(dispatch(:upcase)).to be_nil
    end
  end
end
