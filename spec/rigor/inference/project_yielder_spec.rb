# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::ProjectYielder do
  def repeats?(source)
    def_node = Prism.parse(source).value.statements.body.first
    described_class.repeats?(def_node)
  end

  it "repeats for two yields" do
    expect(repeats?("def m\n  yield\n  yield\nend")).to be(true)
  end

  it "repeats for a yield in a loop or a block" do
    expect(repeats?("def m\n  while c\n    yield\n  end\nend")).to be(true)
    expect(repeats?("def m\n  @items.each { |i| yield i }\nend")).to be(true)
  end

  it "repeats for two calls on the block parameter" do
    expect(repeats?("def m(&blk)\n  blk.call\n  blk.(1)\nend")).to be(true)
  end

  it "repeats when the block is handed on or stored" do
    expect(repeats?("def m(&blk) = @items.each(&blk)")).to be(true)
    expect(repeats?("def m(&) = @items.each(&)")).to be(true)
    expect(repeats?("def m(...) = @items.each(...)")).to be(true)
    expect(repeats?("def m(&blk)\n  @callback = blk\nend")).to be(true)
  end

  it "does not repeat for one run of the block" do
    expect(repeats?("def m\n  yield\nend")).to be(false)
    expect(repeats?("def m(&blk)\n  blk.call\nend")).to be(false)
    expect(repeats?("def m(&blk) = @items.map(&:to_s)")).to be(false)
  end

  it "does not count a yield inside a nested def" do
    expect(repeats?("def m\n  yield\n  def n\n    yield\n  end\nend")).to be(false)
  end
end
