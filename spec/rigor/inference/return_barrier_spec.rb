# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Inference::ReturnBarrier do
  def call_node(source)
    Prism.parse(source).value.statements.body.first
  end

  describe ".block_call?" do
    [
      "lambda",
      "self.lambda",
      "Kernel.lambda",
      "::Kernel.lambda",
      "define_method(:x)",
      "define_singleton_method(:x)",
      "self.define_method(:x)",
      # `define_method` defines a method on its receiver, whichever object that is.
      "klass.define_method(:x)",
      "self.class.define_method(:x)",
      "mod.define_singleton_method(:x)",
      "send(:define_method, :x)",
      "klass.send(:define_method, :x)",
      "__send__(:lambda)",
      "Kernel.__send__(:lambda)",
      "public_send(:define_singleton_method, :x)",
      "mod.public_send(:define_singleton_method, :x)"
    ].each do |call|
      it "is true for `#{call} { }`" do
        expect(described_class.block_call?(call_node("#{call} { }"))).to be(true)
      end
    end

    # A `lambda` on any receiver but `self` or `Kernel` is some other method, and its block an ordinary block.
    %w[proc each tap obj.lambda Foo::Kernel.lambda obj.send(:lambda) send(:each) send(name)].each do |call|
      it "is false for `#{call} { }`" do
        expect(described_class.block_call?(call_node("#{call} { }"))).to be(false)
      end
    end
  end
end
