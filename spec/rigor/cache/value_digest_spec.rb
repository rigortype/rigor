# frozen_string_literal: true

require "spec_helper"
require "rigor/cache/value_digest"

# Issue #1574 — fixtures shaped like rigor-sidekiq's `WorkerIndex`: a frozen row list plus a by-name Hash keyed by
# each row's own frozen name String. Named constants, so Marshal can write them.
module ValueDigestSpecFixtures
  Row = Data.define(:class_name, :arity)
  Pair = Struct.new(:left, :right)

  # A plain object whose state is its instance variables.
  class Index
    def initialize(rows)
      @rows = rows.freeze
      @by_name = rows.to_h { |row| [row.class_name, row] }.freeze
      freeze
    end
  end

  # An object whose `marshal_dump` decides what Marshal (and the digest) keeps of it.
  class Dumped
    def initialize(kept, memo)
      @kept = kept
      @memo = memo
    end

    def marshal_dump = @kept
    def marshal_load(kept) = (@kept = kept)
  end

  # Look-alikes that differ from the fixtures above only in their class.
  OtherRow = Data.define(:class_name, :arity)
  OtherPair = Struct.new(:left, :right)

  class OtherIndex < Index; end

  # Subclasses of the core values, which Marshal writes with their class.
  class StringSub < String; end
  class ArraySub < Array; end
  class HashSub < Hash; end
  class SetSub < Set; end

  # A Data and a Struct whose own readers leave a member out.
  HidingData = Data.define(:shown, :hidden) do
    def to_h = { shown: shown }
  end
  HidingStruct = Struct.new(:shown, :hidden) do
    def each_pair(&) = { shown: shown }.each_pair(&)
  end

  class ParseError < StandardError; end
end

RSpec.describe Rigor::Cache::ValueDigest do
  let(:fixtures) { ValueDigestSpecFixtures }

  def digest(value)
    described_class.hexdigest(value)
  end

  def round_trip(value)
    Marshal.load(Marshal.dump(value))
  end

  # An exception raised while handling a ParseError, so its `cause` is that error. Raised from one line, so two
  # of them differ only in the cause's message.
  def raised_with_cause(message)
    raise fixtures::ParseError, message
  rescue fixtures::ParseError
    begin
      raise "outer"
    rescue RuntimeError => e
      e
    end
  end

  # The structure the issue measured: one frozen String reached as an Array element, a row field and the key of
  # two Hashes. `Marshal.load` rebuilds it unfrozen and `Hash#[]=` stores a frozen copy as the key.
  def shared_key_value
    name = "WelcomeWorker".dup.freeze
    row = fixtures::Row.new(class_name: name, arity: 1)
    { names: [name], rows: [row], by_name: { name => row }, counts: { name => 1 } }
  end

  describe "a value computed and the same value served from a cache" do
    it "digests alike although Marshal writes the two to different bytes" do
      value = shared_key_value
      served = round_trip(value)

      # The precondition: the served copy is equal, but its Marshal bytes are not the computed value's.
      expect(served).to eq(value)
      expect(Marshal.dump(served)).not_to eq(Marshal.dump(value))

      expect(digest(served)).to eq(digest(value))
      expect(digest(round_trip(served))).to eq(digest(value))
    end

    it "digests a plain object keyed by its rows' names alike, as rigor-sidekiq's worker index is" do
      rows = %w[WelcomeWorker DigestWorker].map { |name| fixtures::Row.new(class_name: name.dup.freeze, arity: 1) }
      index = fixtures::Index.new(rows)
      served = round_trip(index)

      expect(Marshal.dump(served)).not_to eq(Marshal.dump(index))
      expect(digest(served)).to eq(digest(index))
    end

    it "digests a shared node and two equal copies of it alike" do
      shared = [1, "a"]
      row = fixtures::Row.new(class_name: "A", arity: 2)

      expect(digest([shared, shared])).to eq(digest([[1, "a"], [1, "a"]]))
      expect(digest([row, row])).to eq(digest([row, fixtures::Row.new(class_name: "A", arity: 2)]))
    end

    it "ignores frozenness and the encoding of an ASCII-only String" do
      expect(digest("abc".dup.freeze)).to eq(digest(+"abc"))
      expect(digest("abc".b)).to eq(digest("abc".encode(Encoding::US_ASCII)))
    end
  end

  describe "a changed value" do
    it "changes the digest when a row, a key or a count moves" do
      base = digest(shared_key_value)
      name = "WelcomeWorker".dup.freeze
      row = fixtures::Row.new(class_name: name, arity: 2)

      expect(digest({ names: [name], rows: [row], by_name: { name => row }, counts: { name => 1 } })).not_to eq(base)
      renamed = "WelcomeJob".dup.freeze
      renamed_row = fixtures::Row.new(class_name: renamed, arity: 1)
      expect(digest({ names: [renamed], rows: [renamed_row], by_name: { renamed => renamed_row },
                      counts: { renamed => 1 } })).not_to eq(base)
      original_row = fixtures::Row.new(class_name: name, arity: 1)
      expect(digest({ names: [name], rows: [original_row], by_name: { name => original_row },
                      counts: { name => 2 } })).not_to eq(base)
    end

    it "gives every one of a set of distinct values its own digest" do
      values = [
        nil, false, true, 0, 1, -1, 2**70, 0.0, -0.0, 1.0, Float::INFINITY, 1r, Complex(1, 2),
        "", "1", "a", :a, "é", "é".b, "a".encode(Encoding::UTF_16LE),
        [], [nil], [1], [[1]], [1, 2], [2, 1], %w[a b], ["ab"],
        {}, { 1 => 2 }, { 2 => 1 }, { "a" => 1 }, { a: 1 }, { a: 1, b: 2 }, { b: 2, a: 1 }, Hash.new(0),
        {}.compare_by_identity, Set[], Set[1], Set[1, 2], Set[2, 1], Set[[]],
        1..2, 1...2, (1..), /a/, /a/i, String, Comparable,
        fixtures::Row.new(class_name: "A", arity: 1), fixtures::Row.new(class_name: "A", arity: 1.0),
        fixtures::Pair.new(1, 2), fixtures::Pair.new(2, 1),
        fixtures::Index.new([]), fixtures::Dumped.new([1], nil),
        Time.at(0, in: "UTC"), Time.at(0, in: "+09:00"), Time.at(1, in: "UTC")
      ]
      digests = values.map { |value| digest(value) }

      expect(digests.uniq.size).to eq(values.size)
    end

    it "keeps a Hash's insertion order, which Marshal keeps too" do
      expect(digest({ a: 1, b: 2 })).not_to eq(digest({ b: 2, a: 1 }))
      expect(digest(round_trip({ b: 2, a: 1 }))).to eq(digest({ b: 2, a: 1 }))
    end

    it "names the class of every object, so look-alikes of another class digest apart" do
      expect(digest(fixtures::Row.new(class_name: "A", arity: 1)))
        .not_to eq(digest(fixtures::OtherRow.new(class_name: "A", arity: 1)))
      expect(digest(fixtures::Pair.new(1, 2))).not_to eq(digest(fixtures::OtherPair.new(1, 2)))
      expect(digest(fixtures::Index.new([]))).not_to eq(digest(fixtures::OtherIndex.new([])))
    end

    it "tags a subclass of String, Array, Hash and Set, which Marshal keeps" do
      pairs = [
        [fixtures::StringSub.new("a"), "a"], [fixtures::ArraySub[1], [1]], [fixtures::HashSub[{ a: 1 }], { a: 1 }],
        [fixtures::SetSub[1], Set[1]]
      ]

      pairs.each do |subclassed, plain|
        expect(digest(subclassed)).not_to eq(digest(plain)), "#{subclassed.class} digested as #{plain.class}"
        expect(digest(round_trip(subclassed))).to eq(digest(subclassed))
      end
    end

    it "keeps a Set's compare_by_identity flag, which Marshal keeps too" do
      by_identity = Set["a"].compare_by_identity

      expect(digest(by_identity)).not_to eq(digest(Set["a"]))
      expect(digest(round_trip(by_identity))).to eq(digest(by_identity))
    end

    it "reads every member of a Data or Struct, past a `to_h` or `each_pair` that leaves one out" do
      expect(digest(fixtures::HidingData.new(shown: 1, hidden: 1)))
        .not_to eq(digest(fixtures::HidingData.new(shown: 1, hidden: 2)))
      expect(digest(fixtures::HidingStruct.new(1, 1))).not_to eq(digest(fixtures::HidingStruct.new(1, 2)))
    end

    it "includes a Struct's instance variables, which Marshal keeps" do
      memoised = ->(memo) { fixtures::Pair.new(1, 2).tap { |pair| pair.instance_variable_set(:@memo, memo) } }

      expect(digest(memoised.call(1))).not_to eq(digest(memoised.call(2)))
      expect(digest(round_trip(memoised.call(1)))).to eq(digest(memoised.call(1)))
    end

    # Marshal keeps an exception's message, backtrace and cause in hidden instance variables, which
    # `instance_variables` does not list.
    it "digests an exception by its class, message, backtrace, cause and instance variables" do
      traced = ->(line) { RuntimeError.new("a").tap { |error| error.set_backtrace(["parse.rb:#{line}"]) } }
      tagged = ->(tag) { RuntimeError.new("a").tap { |error| error.instance_variable_set(:@tag, tag) } }

      expect(digest(RuntimeError.new("a"))).not_to eq(digest(RuntimeError.new("b")))
      expect(digest(RuntimeError.new("a"))).not_to eq(digest(fixtures::ParseError.new("a")))
      expect(digest(traced.call(1))).not_to eq(digest(traced.call(2)))
      expect(digest(raised_with_cause("a"))).not_to eq(digest(raised_with_cause("b")))
      expect(digest(tagged.call(1))).not_to eq(digest(tagged.call(2)))
      expect(digest(round_trip(raised_with_cause("a")))).to eq(digest(raised_with_cause("a")))
    end

    it "digests an object with `marshal_dump` as what that returns, which is what Marshal keeps" do
      expect(digest(fixtures::Dumped.new([1], "memo"))).to eq(digest(fixtures::Dumped.new([1], "other memo")))
      expect(digest(fixtures::Dumped.new([1], nil))).not_to eq(digest(fixtures::Dumped.new([2], nil)))
    end
  end

  describe "a value with no canonical encoding" do
    it "raises Uncanonicalisable rather than digesting what it cannot see" do
      cyclic = []
      cyclic << cyclic
      anonymous = Class.new.new
      undigestible = [
        -> {}, method(:digest), Hash.new { |hash, key| hash[key] = 1 }, cyclic, anonymous, Mutex.new, $stdout,
        Data.define(:a).new(a: 1), { rows: [Object.new, -> {}] }
      ]

      undigestible.each do |value|
        expect { digest(value) }.to raise_error(described_class::Uncanonicalisable), "digested #{value.inspect}"
      end
    end

    it "refuses a structure nested past MAX_DEPTH" do
      deep = (1..(described_class::MAX_DEPTH + 1)).reduce([]) { |inner, _| [inner] }

      expect { digest(deep) }.to raise_error(described_class::Uncanonicalisable)
    end
  end
end
