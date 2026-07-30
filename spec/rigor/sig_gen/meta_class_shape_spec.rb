# frozen_string_literal: true

RSpec.describe Rigor::SigGen::MetaClassShape do
  def rbs_lines(shape) = shape.member_decls.map(&:rbs)

  describe "a Data layout" do
    subject(:shape) { described_class.of(kind: :data, members: %i[amount unit]) }

    it "inherits ::Data" do
      expect(shape.superclass).to eq("::Data")
    end

    it "declares one reader per member and no writer" do
      expect(rbs_lines(shape)).to include("def amount: () -> untyped", "def unit: () -> untyped")
      expect(rbs_lines(shape)).to all(satisfy { |line| !line.include?("=:") })
    end

    # `::Data.new` is declared `() -> bot`, so a subclass that inherits it turns every construction into an arity
    # error. Both call forms exist at runtime, and `.[]` is absent from `::Data`'s RBS entirely.
    it "declares .new and its .[] alias with the keyword and positional forms" do
      expected = "(amount: untyped, unit: untyped) -> instance | (untyped amount, untyped unit) -> instance"

      expect(rbs_lines(shape)).to include("def self.new: #{expected}", "def self.[]: #{expected}")
    end

    it "requires every member — a Data member has no default" do
      expect(rbs_lines(shape).grep(/self\.new/).first).not_to include("?")
    end

    it "renders the supplied member types verbatim" do
      shape = described_class.of(kind: :data, members: %i[amount unit],
                                 member_types: { amount: "Integer", unit: "(String | Symbol)" })

      expect(rbs_lines(shape)).to include(
        "def amount: () -> Integer",
        "def unit: () -> (String | Symbol)",
        "def self.new: (amount: Integer, unit: (String | Symbol)) -> instance " \
        "| (Integer amount, (String | Symbol) unit) -> instance"
      )
    end
  end

  describe "a Struct layout" do
    subject(:shape) { described_class.of(kind: :struct, members: %i[x y]) }

    # RBS rejects a bare `< ::Struct` with InvalidTypeApplicationError — `class Struct[E]` is generic.
    it "inherits ::Struct with an explicit type argument" do
      expect(shape.superclass).to eq("::Struct[untyped]")
    end

    it "declares a writer alongside each reader" do
      expect(rbs_lines(shape)).to include("def x: () -> untyped", "def x=: (untyped) -> untyped")
    end

    # A Struct fills an omitted member with nil, so `Point.new(1)` is legal.
    it "makes every constructor position optional" do
      expect(rbs_lines(shape)).to include(
        "def self.new: (?x: untyped, ?y: untyped) -> instance | (?untyped x, ?untyped y) -> instance"
      )
    end

    it "drops the positional form under keyword_init: true" do
      shape = described_class.of(kind: :struct, members: %i[x y], keyword_init: true)

      expect(rbs_lines(shape)).to include("def self.new: (?x: untyped, ?y: untyped) -> instance")
    end
  end

  it "marks a constructor with no source member so the caller cannot attach a member carrier to it" do
    shape = described_class.of(kind: :data, members: %i[a])

    by_name = shape.member_decls.to_h { |member| [member.method_name, member] }
    expect(by_name[:a].source_member).to eq(:a)
    expect(by_name[:new].source_member).to be_nil
    expect(by_name[:new].kind).to eq(:singleton)
  end
end
