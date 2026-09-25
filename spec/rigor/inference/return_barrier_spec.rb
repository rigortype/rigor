# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Inference::ReturnBarrier do
  def call_node(source)
    Prism.parse(source).value.statements.body.first
  end

  describe ".block_call?" do
    [
      "lambda",
      "define_method(:x)",
      "define_singleton_method(:x)",
      "self.define_method(:x)",
      "send(:define_method, :x)",
      "__send__(:lambda)",
      "public_send(:define_singleton_method, :x)"
    ].each do |call|
      it "is true for `#{call} { }`" do
        expect(described_class.block_call?(call_node("#{call} { }"))).to be(true)
      end
    end

    %w[proc each tap obj.lambda obj.define_method(:x) send(:each) send(name)].each do |call|
      it "is false for `#{call} { }`" do
        expect(described_class.block_call?(call_node("#{call} { }"))).to be(false)
      end
    end
  end
end
