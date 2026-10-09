# frozen_string_literal: true

require "spec_helper"
require "rigor/source/alias_names"

RSpec.describe Rigor::Source::AliasNames do
  def names(source)
    node = Prism.parse(source).value.statements.body.first
    case node
    when Prism::AliasMethodNode then described_class.keyword_names(node)
    when Prism::CallNode then described_class.alias_method_call_names(node)
    end
  end

  it "reads the `alias` keyword with bare identifiers, symbols and operators" do
    expect(names("alias to_m to_modint")).to eq(%i[to_m to_modint])
    expect(names("alias :to_m :to_modint")).to eq(%i[to_m to_modint])
    expect(names("alias old_plus +")).to eq(%i[old_plus +])
  end

  it "reads an implicit-self `alias_method` with Symbol or String literals" do
    expect(names("alias_method :to_mm, :to_modint")).to eq(%i[to_mm to_modint])
    expect(names(%(alias_method "to_ms", "to_modint"))).to eq(%i[to_ms to_modint])
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
      expect(names(source)).to be_nil, source
    end
  end
end
