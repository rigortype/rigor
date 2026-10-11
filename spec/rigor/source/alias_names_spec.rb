# frozen_string_literal: true

require "spec_helper"
require "rigor/source/alias_names"

RSpec.describe Rigor::Source::AliasNames, type: :runner do
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

  # Issue #1821 — a name with bytes no Symbol holds is a computed one, not a crash: `to_sym` raises EncodingError on it.
  it "reads a name with invalid bytes as computed, for `alias_method` and the `alias` keyword" do
    expect(names(%(alias_method "\\xff", :a))).to be_nil
    expect(names(%(alias_method :a, "\\xfe"))).to be_nil
    expect(names(%(alias_method :"\\xff", :a))).to be_nil
    expect(names(%(alias :"\\xff" :a))).to be_nil
    expect(names(%(alias :a :"\\xfe"))).to be_nil
  end

  it "does not abort the analysis of a file whose alias_method name has invalid bytes" do
    source = %(class Foo\n  def x = 1\n  alias_method "\\xff", :x\nend\nFoo.new.x\n)
    expect { analyze(source) }.not_to raise_error
  end

  it "does not abort the analysis of a file whose class-body macro names a method with invalid bytes" do
    source = %(class Foo\n  memoize "\\xff"\n  def x = 1\nend\nFoo.new.x\n)
    expect { analyze(source) }.not_to raise_error
  end

  # `valid_encoding?` is the test, not `ascii_only?`: a name valid in its own encoding is a real Symbol.
  describe "a name that is valid in a non-UTF-8 source encoding" do
    def first_statement(source) = Prism.parse(source.b).value.statements.body.first

    it "is still read from a binary source" do
      node = first_statement("# encoding: binary\nalias_method \"\\xff\", :x\n")
      expect(described_class.alias_method_call_names(node)).to eq([String.new("\xff", encoding: "binary").to_sym, :x])
    end

    it "is still read from a Shift_JIS source" do
      node = first_statement("# encoding: Shift_JIS\nalias_method \"\\x82\\xa0\", :x\n")
      expect(described_class.alias_method_call_names(node)).to eq(
        [String.new("\x82\xA0", encoding: "Shift_JIS").to_sym, :x]
      )
    end
  end
end
