# frozen_string_literal: true

RSpec.describe Rigor::Inference::MethodDispatcher::ArrayToHFolding do
  def constant(value) = Rigor::Type::Combinator.constant_of(value)
  def tuple(*elements) = Rigor::Type::Combinator.tuple_of(*elements)
  def nominal(name) = Rigor::Type::Combinator.nominal_of(name)
  def array_of(*type_args) = Rigor::Type::Combinator.nominal_of("Array", type_args: type_args)
  def hash_of(key, value) = Rigor::Type::Combinator.nominal_of("Hash", type_args: [key, value])

  def dispatch(receiver:, block_type:)
    described_class.try_dispatch(
      cc(receiver: receiver, method_name: :to_h, args: [], block_type: block_type)
    )
  end

  describe "Array#to_h { |x| [k, v] } (B5)" do
    it "projects a 2-Tuple block return into Hash[K, V]" do
      result = dispatch(receiver: tuple(constant(1), constant(2)),
                        block_type: tuple(constant(:a), constant(1)))
      expect(result).to eq(hash_of(nominal("Symbol"), nominal("Integer")))
    end

    it "widens value-pinned pair members to their nominal" do
      result = dispatch(receiver: array_of(nominal("Integer")),
                        block_type: tuple(constant("k"), constant(2)))
      expect(result).to eq(hash_of(nominal("String"), nominal("Integer")))
    end

    it "preserves non-Constant pair member types unchanged" do
      result = dispatch(receiver: tuple(constant(1)),
                        block_type: tuple(nominal("String"), array_of(nominal("Integer"))))
      expect(result).to eq(hash_of(nominal("String"), array_of(nominal("Integer"))))
    end

    it "declines when the block return is not a Tuple" do
      expect(dispatch(receiver: tuple(constant(1)), block_type: nominal("Integer"))).to be_nil
    end

    it "declines when the block return Tuple is not a 2-element pair" do
      expect(dispatch(receiver: tuple(constant(1)),
                      block_type: tuple(constant(:a), constant(1), constant(2)))).to be_nil
    end

    it "declines when there is no block at the call site" do
      expect(dispatch(receiver: tuple(constant(1)), block_type: nil)).to be_nil
    end

    it "declines for a non-Array receiver" do
      expect(dispatch(receiver: nominal("Hash"),
                      block_type: tuple(constant(:a), constant(1)))).to be_nil
    end

    it "declines for a non-to_h method" do
      result = described_class.try_dispatch(
        cc(receiver: tuple(constant(1)), method_name: :map, args: [],
           block_type: tuple(constant(:a), constant(1)))
      )
      expect(result).to be_nil
    end
  end
end
