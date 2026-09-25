# frozen_string_literal: true

RSpec.describe Rigor::SigGen::InlineMerge do
  def types(*strings)
    strings.map { |string| RBS::Parser.parse_method_type(string) }
  end

  def merge(authored, written, return_defaulted: false)
    described_class.merge(types(*authored), types(*written), return_defaulted: return_defaulted)&.map(&:to_s)
  end

  it "keeps a sig/ parameter where the inline slot is rbs-inline's `untyped` default" do
    expect(merge(["(String a, untyped b) -> Integer"], ["(Symbol a, Integer b) -> Integer"]))
      .to eq(["(String a, Integer b) -> Integer"])
  end

  it "keeps the sig/ block where the inline one is the `?{ (?) -> untyped }` default" do
    expect(merge(["(String a) ?{ (?) -> untyped } -> Integer"], ["(String a) { (String) -> void } -> Integer"]))
      .to eq(["(String a) { (String) -> void } -> Integer"])
  end

  it "keeps the sig/ return only when the inline return was defaulted" do
    expect(merge(["(String a) -> untyped"], ["(String a) -> Array[String]"], return_defaulted: true))
      .to eq(["(String a) -> Array[String]"])
    expect(merge(["(String a) -> untyped"], ["(String a) -> Array[String]"]))
      .to eq(["(String a) -> untyped"])
  end

  it "keeps the sig/ parameters under an inline `(?)`, and takes the authored ones over a sig/ `(?)`" do
    expect(merge(["(?) -> String"], ["(Integer a) -> Object"])).to eq(["(Integer a) -> String"])
    expect(merge(["(Integer a) -> String"], ["(?) -> Object"])).to eq(["(Integer a) -> String"])
  end

  it "answers nil for a different overload count or parameter shape" do
    expect(merge(["(String a) -> untyped"], ["(String a) -> Integer", "(Integer a) -> Integer"])).to be_nil
    expect(merge(["(String a, untyped b) -> Integer"], ["(String a) -> Integer"])).to be_nil
    expect(merge(["(k: String) -> Integer"], ["(j: String) -> Integer"])).to be_nil
  end
end
