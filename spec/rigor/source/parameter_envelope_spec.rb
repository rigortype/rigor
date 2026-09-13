# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/source/parameter_envelope"

# Issue #992 — the positional envelope `call.wrong-arity` checks an undeclared `def` against. The table is
# the contract: `[min, max, required_keywords]`, `max` nil when unbounded.
RSpec.describe Rigor::Source::ParameterEnvelope do
  def envelope_of(source)
    def_node = Prism.parse(source).value.statements.body.first
    described_class.of(def_node)
  end

  {
    "def f; end" => [0, 0, false],
    "def f(); end" => [0, 0, false],
    "def f(a); end" => [1, 1, false],
    "def f(a, b); end" => [2, 2, false],
    "def f(a = 1); end" => [0, 1, false],
    "def f(a, b = 1, c = 2); end" => [1, 3, false],
    "def f(*rest); end" => [0, nil, false],
    "def f(*); end" => [0, nil, false],
    "def f(a, *rest); end" => [1, nil, false],
    "def f(a, b = 1, *rest, c); end" => [2, nil, false],
    "def f(a, c); end" => [2, 2, false],
    "def f(a = 1, c); end" => [1, 2, false],
    "def f((a, b), c); end" => [2, 2, false],
    "def f(...); end" => [0, nil, false],
    "def f(a, ...); end" => [1, nil, false],
    "def f(a, k: 1); end" => [1, 1, false],
    "def f(a, **opts); end" => [1, 1, false],
    "def f(a, **); end" => [1, 1, false],
    "def f(a, **nil); end" => [1, 1, false],
    "def f(a, &block); end" => [1, 1, false],
    "def f(a, &); end" => [1, 1, false],
    "def f(a, k:); end" => [1, 1, true],
    "def f(k:, j: 2); end" => [0, 0, true],
    "def self.f(a, b = 1); end" => [1, 2, false],
    "def f(a) = a" => [1, 1, false]
  }.each do |source, expected|
    it "reads `#{source}` as #{expected.inspect}" do
      expect(envelope_of(source)).to eq(expected)
    end
  end

  it "ignores the body: `super`, `yield` and a block argument do not widen the def's own envelope" do
    expect(envelope_of("def f(a)\n  super\n  yield a\n  g(&nil)\nend")).to eq([1, 1, false])
  end

  it "returns frozen plain data, so a seed bundle carries it through Marshal unchanged" do
    envelope = envelope_of("def f(a, *r); end")
    expect(envelope).to be_frozen
    expect(Marshal.load(Marshal.dump(envelope))).to eq(envelope)
  end

  describe ".merge" do
    let(:one) { [1, 1, false] }
    let(:two) { [2, 2, false] }
    let(:opaque) { described_class::OPAQUE }

    it "keeps an envelope every contribution agrees on" do
      expect(described_class.merge(one, one.dup)).to eq(one)
    end

    it "makes a disagreement opaque instead of keeping either side" do
      expect(described_class.merge(one, two)).to eq(opaque)
      expect(described_class.merge(two, one)).to eq(opaque)
    end

    it "lets opaque absorb, in either order" do
      expect(described_class.merge(one, opaque)).to eq(opaque)
      expect(described_class.merge(opaque, one)).to eq(opaque)
    end

    it "treats an absent side as no contribution" do
      expect(described_class.merge(nil, one)).to eq(one)
      expect(described_class.merge(one, nil)).to eq(one)
    end

    it "joins whole tables per class and per key" do
      base = { "A" => { %i[instance f] => one, %i[instance g] => one } }
      overlay = { "A" => { %i[instance f] => two }, "B" => { %i[singleton h] => one } }
      expect(described_class.merge_tables(base, overlay)).to eq(
        "A" => { %i[instance f] => opaque, %i[instance g] => one },
        "B" => { %i[singleton h] => one }
      )
    end
  end
end
