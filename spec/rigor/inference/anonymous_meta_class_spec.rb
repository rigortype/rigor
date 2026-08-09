# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::AnonymousMetaClass do
  def call_node(source)
    statement = Prism.parse(source).value.statements.body.first
    statement.is_a?(Prism::CallNode) ? statement : statement.value
  end

  describe ".block_form_receiver" do
    it "recognises every class-creating meta call that carries a block" do
      expect(described_class.block_form_receiver(call_node("Class.new do; end"))).to eq(:Class)
      expect(described_class.block_form_receiver(call_node("Module.new do; end"))).to eq(:Module)
      expect(described_class.block_form_receiver(call_node("Struct.new(:x) do; end"))).to eq(:Struct)
      expect(described_class.block_form_receiver(call_node("Data.define(:x) do; end"))).to eq(:Data)
      expect(described_class.block_form_receiver(call_node("::Class.new do; end"))).to eq(:Class)
    end

    it "accepts a superclass argument — the block is a class body whatever the arguments are" do
      expect(described_class.block_form_receiver(call_node("Class.new(StandardError) { }"))).to eq(:Class)
    end

    it "declines a call with no block: there is no body to treat as a class body" do
      expect(described_class.block_form_receiver(call_node("Class.new"))).to be_nil
      expect(described_class.block_form_receiver(call_node("Class.new(StandardError)"))).to be_nil
    end

    it "declines a receiver whose identity is not statically known" do
      expect(described_class.block_form_receiver(call_node("klass.new do; end"))).to be_nil
      expect(described_class.block_form_receiver(call_node("Foo::Class.new do; end"))).to be_nil
      expect(described_class.block_form_receiver(call_node("Class.allocate do; end"))).to be_nil
      expect(described_class.block_form_receiver(call_node("Data.new(:x) do; end"))).to be_nil
    end
  end

  describe ".name_for" do
    it "keys the name by receiver, source path and call-site position" do
      expect(described_class.name_for(call_node("Class.new do; end"), "lib/a.rb")).to eq("#<Class:lib/a.rb:1:0>")
    end

    it "omits the path segment when the caller has none, so both passes agree on the same nil" do
      expect(described_class.name_for(call_node("Module.new do; end"))).to eq("#<Module:1:0>")
    end

    it "spells a name no constant path can produce, so it cannot collide with a real class" do
      name = described_class.name_for(call_node("Class.new do; end"), "lib/a.rb")
      expect(Rigor::Type::AnonymousClassName.match?(name)).to be(true)
      expect(Rigor::Type::AnonymousClassName.match?("Foo::Bar")).to be(false)
    end

    it "renders without its position key, and erases out of RBS entirely" do
      name = described_class.name_for(call_node("Class.new do; end"), "lib/a.rb")

      expect(Rigor::Type::Combinator.singleton_of(name).describe(:short)).to eq("singleton(#<Class>)")
      expect(Rigor::Type::Combinator.nominal_of(name).describe(:short)).to eq("#<Class>")
      expect(Rigor::Type::Combinator.singleton_of(name).erase_to_rbs).to eq("untyped")
      expect(Rigor::Type::Combinator.nominal_of(name).erase_to_rbs).to eq("untyped")
    end

    it "returns nil for a call it does not recognise" do
      expect(described_class.name_for(call_node("Class.new"), "lib/a.rb")).to be_nil
    end
  end
end
