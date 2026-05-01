# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::ClosureEscapeAnalyzer do
  def array_nominal = Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Top.instance])
  def hash_nominal = Rigor::Type::Combinator.nominal_of("Hash")
  def range_nominal = Rigor::Type::Combinator.nominal_of("Range")
  def integer_nominal = Rigor::Type::Combinator.nominal_of("Integer")
  def string_nominal = Rigor::Type::Combinator.nominal_of("String")
  def module_singleton = Rigor::Type::Combinator.singleton_of("Module")
  def thread_singleton = Rigor::Type::Combinator.singleton_of("Thread")

  def classify(type, method) = described_class.classify(receiver_type: type, method_name: method)

  describe ".classify" do
    context "with non-escaping core iteration" do
      it "recognises Array#each / map / select / inject" do
        %i[each map select inject reduce flat_map filter_map any? all?].each do |m|
          expect(classify(array_nominal, m)).to eq(:non_escaping), "expected Array##{m} to be non_escaping"
        end
      end

      it "recognises Hash#each_pair / transform_values" do
        %i[each_pair each_key each_value transform_values transform_keys].each do |m|
          expect(classify(hash_nominal, m)).to eq(:non_escaping)
        end
      end

      it "recognises Range#each, Range#step, Range#map" do
        %i[each step map].each do |m|
          expect(classify(range_nominal, m)).to eq(:non_escaping)
        end
      end

      it "recognises Integer#times / upto / downto" do
        %i[times upto downto].each { |m| expect(classify(integer_nominal, m)).to eq(:non_escaping) }
      end

      it "recognises Object#tap / then / yield_self on any receiver" do
        %i[tap then yield_self].each do |m|
          expect(classify(string_nominal, m)).to eq(:non_escaping)
          expect(classify(integer_nominal, m)).to eq(:non_escaping)
        end
      end
    end

    context "with carriers projecting to a class" do
      it "treats a Tuple receiver as Array" do
        tuple = Rigor::Type::Tuple.new([Rigor::Type::Combinator.constant_of(1)])
        expect(classify(tuple, :each)).to eq(:non_escaping)
      end

      it "treats a HashShape receiver as Hash" do
        shape = Rigor::Type::HashShape.new(entries: { name: Rigor::Type::Combinator.constant_of("Alice") })
        expect(classify(shape, :each_pair)).to eq(:non_escaping)
      end

      it "treats Constant[scalar] receivers via their value class" do
        expect(classify(Rigor::Type::Combinator.constant_of(3), :times)).to eq(:non_escaping)
        expect(classify(Rigor::Type::Combinator.constant_of("hi"), :tap)).to eq(:non_escaping)
      end
    end

    context "with proven escaping methods" do
      it "flags Module#define_method as escaping" do
        expect(classify(module_singleton, :define_method)).to eq(:escaping)
      end

      it "flags Thread.new / start / fork as escaping" do
        %i[new start fork].each { |m| expect(classify(thread_singleton, m)).to eq(:escaping) }
      end

      it "flags Proc.new as escaping" do
        expect(classify(Rigor::Type::Combinator.singleton_of("Proc"), :new)).to eq(:escaping)
      end
    end

    context "when receiver or method is outside the catalogue" do
      it "returns :unknown for nil receiver" do
        expect(classify(nil, :each)).to eq(:unknown)
      end

      it "returns :unknown for Top / Dynamic / Union receivers" do
        expect(classify(Rigor::Type::Top.instance, :each)).to eq(:unknown)
        expect(classify(Rigor::Type::Dynamic.new(Rigor::Type::Top.instance), :each)).to eq(:unknown)
        union = Rigor::Type::Combinator.union(array_nominal, hash_nominal)
        expect(classify(union, :each)).to eq(:unknown)
      end

      it "returns :unknown for catalogued classes on uncatalogued methods" do
        expect(classify(array_nominal, :unknown_method)).to eq(:unknown)
      end

      it "returns :unknown for receivers outside the catalogue" do
        expect(classify(string_nominal, :each_char)).to eq(:unknown)
      end

      it "is deterministic across calls" do
        2.times { expect(classify(array_nominal, :map)).to eq(:non_escaping) }
      end
    end

    it "ignores the environment kwarg in sub-phase 3a" do
      env = Rigor::Environment.new
      result = described_class.classify(receiver_type: array_nominal, method_name: :each, environment: env)
      expect(result).to eq(:non_escaping)
    end
  end
end
