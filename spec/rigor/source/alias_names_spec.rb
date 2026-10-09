# frozen_string_literal: true

require "spec_helper"
require "rigor/source/alias_names"

RSpec.describe Rigor::Source::AliasNames do
  def first_statement(source)
    Prism.parse(source).value.statements.body.first
  end

  it "reads the `alias` keyword with bare identifiers, symbols and operators" do
    expect(described_class.of(first_statement("alias to_m to_modint"))).to eq(%i[to_m to_modint])
    expect(described_class.of(first_statement("alias :to_m :to_modint"))).to eq(%i[to_m to_modint])
    expect(described_class.of(first_statement("alias old_plus +"))).to eq(%i[old_plus +])
  end

  it "reads an implicit-self `alias_method` with Symbol or String literals" do
    expect(described_class.of(first_statement("alias_method :to_mm, :to_modint"))).to eq(%i[to_mm to_modint])
    expect(described_class.of(first_statement(%(alias_method "to_ms", "to_modint")))).to eq(%i[to_ms to_modint])
  end

  it "declines computed names, receivers, other arities and other nodes" do
    [
      "alias :\"a\#{x}\" b",
      "alias_method name, :to_modint",
      "self.alias_method :a, :b",
      "alias_method :a",
      "define_method :a, :b",
      "alias $new $old"
    ].each do |source|
      expect(described_class.of(first_statement(source))).to be_nil, source
    end
  end
end
