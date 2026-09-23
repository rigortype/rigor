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

      it "recognises IO / File line iteration, singleton foreach and instance each_line/each_char" do
        # File.foreach's receiver is singleton(File); io.each_line's is a File / IO instance. Both must be
        # non_escaping so the loop-body re-narrowing applies (a local written in one `when` arm is visible in
        # a sibling arm across iterations) — otherwise a guarding condition folds to a spurious constant and a
        # block-level `return` is dropped from the method's return summary.
        expect(classify(Rigor::Type::Combinator.singleton_of("File"), :foreach)).to eq(:non_escaping)
        expect(classify(Rigor::Type::Combinator.singleton_of("IO"), :foreach)).to eq(:non_escaping)
        %i[each_line each each_byte each_char each_codepoint].each do |m|
          expect(classify(Rigor::Type::Combinator.nominal_of("File"), m)).to eq(:non_escaping)
          expect(classify(Rigor::Type::Combinator.nominal_of("IO"), m)).to eq(:non_escaping)
        end
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

  describe ".discards_block_value?" do
    def discards?(type, method) = described_class.discards_block_value?(receiver_type: type, method_name: method)

    it "answers true for iterators that return the receiver, a memo or nil" do
      expect(discards?(array_nominal, :each)).to be(true)
      expect(discards?(array_nominal, :each_with_object)).to be(true)
      expect(discards?(hash_nominal, :each_pair)).to be(true)
      expect(discards?(range_nominal, :step)).to be(true)
      expect(discards?(integer_nominal, :times)).to be(true)
      expect(discards?(Rigor::Type::Combinator.singleton_of("File"), :foreach)).to be(true)
    end

    it "resolves shape receivers through their class, as classify does" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.constant_of(1))
      expect(discards?(tuple, :each)).to be(true)
    end

    it "answers false for iterators whose result is built from the block's values" do
      expect(discards?(array_nominal, :map)).to be(false)
      expect(discards?(array_nominal, :find)).to be(false)
      expect(discards?(hash_nominal, :transform_values)).to be(false)
    end

    it "answers false for Enumerator#each, whose result is the underlying method's" do
      expect(discards?(Rigor::Type::Combinator.nominal_of("Enumerator"), :each)).to be(false)
    end

    it "answers false for receivers it cannot resolve" do
      expect(discards?(nil, :each)).to be(false)
      expect(discards?(Rigor::Type::Combinator.untyped, :each)).to be(false)
      expect(discards?(string_nominal, :each)).to be(false)
    end
  end
end
