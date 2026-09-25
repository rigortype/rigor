# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::BlockFolding do
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def tuple_of(*elems) = Rigor::Type::Combinator.tuple_of(*elems)
  def array_of(elem) = Rigor::Type::Combinator.nominal_of("Array", type_args: [elem])
  def integer_nominal = Rigor::Type::Combinator.nominal_of("Integer")
  def string_nominal = Rigor::Type::Combinator.nominal_of("String")
  def non_empty_array(elem) = Rigor::Type::Combinator.non_empty_array(elem)
  def hash_shape_of(pairs) = Rigor::Type::Combinator.hash_shape_of(pairs)
  def true_const = constant_of(true)
  def false_const = constant_of(false)
  def bool_union = Rigor::Type::Combinator.union(true_const, false_const)

  def fold(receiver:, method:, block:, args: [])
    described_class.try_dispatch(cc(
                                   receiver: receiver, method_name: method, args: args, block_type: block
                                 ))
  end

  describe "filter-shaped folds (block returns Constant[false] → empty)" do
    it "select { false } on a Tuple receiver folds to the empty tuple" do
      result = fold(receiver: tuple_of(constant_of(1), constant_of(2)),
                    method: :select, block: false_const)
      expect(result).to eq(tuple_of)
    end

    it "filter { false } on Array[Integer] folds to the empty tuple" do
      # `filter` is an alias of `select` in Ruby; we cover it explicitly because the dispatcher receives the raw method
      # name.
      result = fold(receiver: array_of(integer_nominal), method: :filter, block: false_const)
      expect(result).to eq(tuple_of)
    end

    it "take_while { false } folds to the empty tuple" do
      result = fold(receiver: array_of(integer_nominal), method: :take_while, block: false_const)
      expect(result).to eq(tuple_of)
    end

    it "drop_while { true } folds to the empty tuple" do
      result = fold(receiver: array_of(integer_nominal), method: :drop_while, block: true_const)
      expect(result).to eq(tuple_of)
    end

    it "reject { true } folds to the empty tuple" do
      result = fold(receiver: array_of(integer_nominal), method: :reject, block: true_const)
      expect(result).to eq(tuple_of)
    end
  end

  describe "filter-shaped folds (block returns Constant[true] → receiver shape)" do
    it "select { true } on Array[T] returns Array[T]" do
      result = fold(receiver: array_of(integer_nominal), method: :select, block: true_const)
      expect(result).to eq(array_of(integer_nominal))
    end

    it "reject { false } on Array[T] returns Array[T]" do
      result = fold(receiver: array_of(integer_nominal), method: :reject, block: false_const)
      expect(result).to eq(array_of(integer_nominal))
    end

    it "take_while { true } on Array[T] returns Array[T]" do
      result = fold(receiver: array_of(integer_nominal), method: :take_while, block: true_const)
      expect(result).to eq(array_of(integer_nominal))
    end

    it "drop_while { false } on Array[T] returns Array[T]" do
      result = fold(receiver: array_of(integer_nominal), method: :drop_while, block: false_const)
      expect(result).to eq(array_of(integer_nominal))
    end

    it "select { true } on a Tuple widens to Array[union] (sub-multisets are unknowable per-position)" do
      tup = tuple_of(integer_nominal, string_nominal)
      result = fold(receiver: tup, method: :select, block: true_const)
      expect(result).to eq(array_of(Rigor::Type::Combinator.union(integer_nominal, string_nominal)))
    end
  end

  describe "filter-shaped folds over a Hash receiver (the result kind follows the method, not the receiver)" do
    def hash_nominal = Rigor::Type::Combinator.nominal_of("Hash", type_args: [symbol_nominal, integer_nominal])
    def symbol_nominal = Rigor::Type::Combinator.nominal_of("Symbol")
    def non_empty_hash = Rigor::Type::Combinator.non_empty_hash(symbol_nominal, integer_nominal)
    def shape = hash_shape_of(a: constant_of(:q))

    # `Hash#select` / `#filter` / `#reject` return a Hash: `{ a: :q }.reject { true } == {}`.
    [[:select, false], [:filter, false], [:reject, true]].each do |method, block_value|
      it "#{method} { #{block_value} } on a HashShape folds to the empty HashShape" do
        expect(fold(receiver: shape, method: method, block: constant_of(block_value))).to eq(hash_shape_of({}))
      end

      it "#{method} { #{block_value} } on Hash[K, V] folds to the empty HashShape" do
        expect(fold(receiver: hash_nominal, method: method, block: constant_of(block_value)))
          .to eq(hash_shape_of({}))
      end

      it "#{method} { #{block_value} } on non-empty-hash folds to the empty HashShape" do
        expect(fold(receiver: non_empty_hash, method: method, block: constant_of(block_value)))
          .to eq(hash_shape_of({}))
      end

      it "#{method} { #{!block_value} } on a HashShape keeps the receiver shape" do
        expect(fold(receiver: shape, method: method, block: constant_of(!block_value))).to eq(shape)
      end

      it "#{method} { #{!block_value} } on Hash[K, V] and non-empty-hash keeps the receiver" do
        expect(fold(receiver: hash_nominal, method: method, block: constant_of(!block_value))).to eq(hash_nominal)
        expect(fold(receiver: non_empty_hash, method: method, block: constant_of(!block_value))).to eq(non_empty_hash)
      end
    end

    # `Hash#take_while` / `#drop_while` are Enumerable's and return an Array of `[key, value]` pairs:
    # `{ a: :q }.take_while { false } == []`, `{ a: :q }.take_while { true } == [[:a, :q]]`.
    it "take_while { false } on a HashShape folds to the empty tuple" do
      expect(fold(receiver: shape, method: :take_while, block: false_const)).to eq(tuple_of)
    end

    it "drop_while { true } on Hash[K, V] folds to the empty tuple" do
      expect(fold(receiver: hash_nominal, method: :drop_while, block: true_const)).to eq(tuple_of)
    end

    it "take_while { true } on a HashShape declines rather than answer the Hash receiver" do
      expect(fold(receiver: shape, method: :take_while, block: true_const)).to be_nil
    end

    it "drop_while { false } on Hash[K, V] declines rather than answer the Hash receiver" do
      expect(fold(receiver: hash_nominal, method: :drop_while, block: false_const)).to be_nil
    end
  end

  describe "filter-shaped folds over a Set or Range receiver (Enumerable's, so they return an Array)" do
    def set_nominal = Rigor::Type::Combinator.nominal_of("Set", type_args: [integer_nominal])
    def range_nominal = Rigor::Type::Combinator.nominal_of("Range", type_args: [integer_nominal])

    it "select { false } on a folded Set constant folds to the empty tuple" do
      expect(fold(receiver: constant_of(Set[1, 2]), method: :select, block: false_const)).to eq(tuple_of)
    end

    it "select { true } on a folded Set constant declines rather than answer the Set receiver" do
      # `Set[1, 2].select { true } == [1, 2]` — `Set` does not define `select`, so `Enumerable#select` answers.
      expect(fold(receiver: constant_of(Set[1, 2]), method: :select, block: true_const)).to be_nil
    end

    it "reject { false } on Set[T] declines rather than answer the Set receiver" do
      expect(fold(receiver: set_nominal, method: :reject, block: false_const)).to be_nil
    end

    it "select { true } on Range[T] declines rather than answer the Range receiver" do
      expect(fold(receiver: range_nominal, method: :select, block: true_const)).to be_nil
    end

    it "select { true } on a Range constant declines rather than answer the Range receiver" do
      expect(fold(receiver: constant_of(1..3), method: :select, block: true_const)).to be_nil
    end

    it "reject { true } on Range[T] folds to the empty tuple" do
      expect(fold(receiver: range_nominal, method: :reject, block: true_const)).to eq(tuple_of)
    end

    it "declines on a non-collection Constant or Difference receiver" do
      non_empty_string = Rigor::Type::Combinator.non_empty_string
      expect(fold(receiver: constant_of("abc"), method: :select, block: false_const)).to be_nil
      expect(fold(receiver: non_empty_string, method: :select, block: false_const)).to be_nil
    end
  end

  describe "any?/all?/none? predicate folds with constant block" do
    it "all? { true } folds to Constant[true] regardless of receiver shape" do
      expect(fold(receiver: array_of(integer_nominal), method: :all?, block: true_const))
        .to eq(true_const)
      expect(fold(receiver: tuple_of, method: :all?, block: true_const)).to eq(true_const)
      expect(fold(receiver: tuple_of(integer_nominal), method: :all?, block: true_const))
        .to eq(true_const)
    end

    it "all? { false } folds to Constant[false] on a non-empty receiver" do
      expect(fold(receiver: tuple_of(integer_nominal), method: :all?, block: false_const))
        .to eq(false_const)
      expect(fold(receiver: non_empty_array(integer_nominal), method: :all?, block: false_const))
        .to eq(false_const)
    end

    it "all? { false } folds to Constant[true] on an empty receiver (vacuous)" do
      expect(fold(receiver: tuple_of, method: :all?, block: false_const)).to eq(true_const)
    end

    it "all? { false } widens to bool when the receiver's emptiness is unknown" do
      expect(fold(receiver: array_of(integer_nominal), method: :all?, block: false_const))
        .to eq(bool_union)
    end

    it "any? { false } folds to Constant[false] regardless of receiver shape" do
      expect(fold(receiver: array_of(integer_nominal), method: :any?, block: false_const))
        .to eq(false_const)
      expect(fold(receiver: tuple_of(integer_nominal), method: :any?, block: false_const))
        .to eq(false_const)
    end

    it "any? { true } folds to Constant[true] on a non-empty receiver" do
      expect(fold(receiver: tuple_of(integer_nominal), method: :any?, block: true_const))
        .to eq(true_const)
      expect(fold(receiver: non_empty_array(integer_nominal), method: :any?, block: true_const))
        .to eq(true_const)
    end

    it "any? { true } folds to Constant[false] on an empty receiver" do
      expect(fold(receiver: tuple_of, method: :any?, block: true_const)).to eq(false_const)
    end

    it "any? { true } widens to bool when receiver emptiness is unknown" do
      expect(fold(receiver: array_of(integer_nominal), method: :any?, block: true_const))
        .to eq(bool_union)
    end

    it "none? { false } folds to Constant[true] regardless of receiver shape" do
      expect(fold(receiver: array_of(integer_nominal), method: :none?, block: false_const))
        .to eq(true_const)
      expect(fold(receiver: tuple_of(integer_nominal), method: :none?, block: false_const))
        .to eq(true_const)
    end

    it "none? { true } folds to Constant[false] on a non-empty receiver" do
      expect(fold(receiver: tuple_of(integer_nominal), method: :none?, block: true_const))
        .to eq(false_const)
    end

    it "none? { true } folds to Constant[true] on an empty receiver" do
      expect(fold(receiver: tuple_of, method: :none?, block: true_const)).to eq(true_const)
    end

    # With a pattern argument Ruby tests `pattern === element` and ignores the block ("given block not used"),
    # so the block's truthiness decides nothing: `[1, 2].all?(String) { true }` is `false`.
    %i[all? any? none?].each do |method|
      it "declines `#{method}(pattern) { … }`, whose block Ruby ignores" do
        pattern = Rigor::Type::Combinator.singleton_of("String")
        results = [true_const, false_const].product([tuple_of(integer_nominal), tuple_of]).map do |block, receiver|
          fold(receiver: receiver, method: method, block: block, args: [pattern])
        end

        expect(results).to all(be_nil)
      end
    end
  end

  describe "predicate folds with a pattern argument", type: :runner do
    def reported_rules(source)
      analyze(source).diagnostics.filter_map do |diagnostic|
        diagnostic.qualified_rule if diagnostic.severity == :error || diagnostic.rule.to_s.start_with?("flow.")
      end
    end

    # Each value is the opposite of what the ignored block says (`false`, `true`, `false` at runtime), so the
    # folded constant made the condition read as always truthy or always falsey.
    it "no longer folds the ignored block's answer into a condition" do
      expect(reported_rules(<<~RUBY)).to be_empty
        xs = [Integer(ARGV.first), 2]
        a = xs.all?(String) { |e| true }
        puts "a" if a
        b = xs.any?(Integer) { |e| false }
        puts "b" if b
        c = xs.none?(Integer) { |e| false }
        puts "c" if c
      RUBY
    end

    # The paired control: without a pattern the block decides, and the condition still folds.
    it "still folds the block-only form" do
      expect(reported_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        xs = [Integer(ARGV.first), 2]
        b = xs.any? { |e| false }
        puts "b" if b
      RUBY
    end
  end

  describe "find/detect/find_index/index falsey-block short-circuit" do
    %i[find detect find_index index].each do |method|
      it "folds `#{method} { false }` to Constant[nil]" do
        result = fold(receiver: array_of(integer_nominal), method: method, block: false_const)
        expect(result).to eq(constant_of(nil))
      end

      it "declines on the truthy side (per-position analysis is a future slice)" do
        result = fold(receiver: array_of(integer_nominal), method: method, block: true_const)
        expect(result).to be_nil
      end

      it "declines when called with a positional argument (value-search form)" do
        result = fold(receiver: array_of(integer_nominal), method: method, block: false_const,
                      args: [constant_of(0)])
        expect(result).to be_nil
      end
    end
  end

  describe "count with a block" do
    it "folds count { false } to Constant[0] regardless of receiver shape" do
      expect(fold(receiver: array_of(integer_nominal), method: :count, block: false_const))
        .to eq(constant_of(0))
      expect(fold(receiver: tuple_of(integer_nominal, integer_nominal), method: :count, block: false_const))
        .to eq(constant_of(0))
    end

    it "folds count { true } to Constant[size] on a Tuple receiver" do
      tup = tuple_of(integer_nominal, string_nominal, integer_nominal)
      expect(fold(receiver: tup, method: :count, block: true_const)).to eq(constant_of(3))
    end

    it "folds count { true } to Constant[0] on the empty Tuple" do
      expect(fold(receiver: tuple_of, method: :count, block: true_const)).to eq(constant_of(0))
    end

    it "folds count { true } over a finite-bound Range constant" do
      # `(1..5).count { true }` — the inclusive integer range has 5 elements, so the truthy block sees all of them.
      const_range = constant_of(1..5)
      expect(fold(receiver: const_range, method: :count, block: true_const)).to eq(constant_of(5))
    end

    it "declines count { true } when receiver size is unknown (Array[T])" do
      expect(fold(receiver: array_of(integer_nominal), method: :count, block: true_const))
        .to be_nil
    end

    it "declines when count carries a positional argument (value-count form)" do
      expect(fold(receiver: array_of(integer_nominal), method: :count, block: false_const,
                  args: [constant_of(0)])).to be_nil
    end
  end

  describe "min_by / max_by on a non-empty receiver (issue #1333)" do
    let(:any_key) { integer_nominal }

    %i[min_by max_by].each do |method|
      it "folds `#{method}` on a non-empty Tuple to the element union, whatever the block's key" do
        tup = tuple_of(constant_of(1), string_nominal)
        expect(fold(receiver: tup, method: method, block: any_key))
          .to eq(Rigor::Type::Combinator.union(constant_of(1), string_nominal))
      end

      it "folds `#{method}` on a non-empty constant integer Range to its element range" do
        expect(fold(receiver: constant_of(2..4), method: method, block: any_key))
          .to eq(Rigor::Type::Combinator.integer_range(2, 4))
      end

      it "declines `#{method}` on an empty receiver" do
        expect(fold(receiver: tuple_of, method: method, block: any_key)).to be_nil
        expect(fold(receiver: constant_of(1...1), method: method, block: any_key)).to be_nil
      end

      it "declines `#{method}` when the receiver's size is not static" do
        expect(fold(receiver: array_of(integer_nominal), method: method, block: any_key)).to be_nil
        expect(fold(receiver: constant_of(1..), method: method, block: any_key)).to be_nil
      end

      it "declines the count form `#{method}(n) { … }`" do
        expect(fold(receiver: tuple_of(constant_of(1), constant_of(2)), method: method, block: any_key,
                    args: [constant_of(1)])).to be_nil
      end

      it "declines `#{method}` without a block (the Enumerator form)" do
        expect(fold(receiver: tuple_of(constant_of(1)), method: method, block: nil)).to be_nil
      end
    end
  end

  describe "decline cases (return nil so RBS / iterator tier answers)" do
    it "declines when block_type is nil (no block at the call site)" do
      expect(fold(receiver: array_of(integer_nominal), method: :select, block: nil)).to be_nil
    end

    it "declines when block_type is bool_union (block can return either)" do
      result = fold(receiver: array_of(integer_nominal), method: :select, block: bool_union)
      expect(result).to be_nil
    end

    it "declines for unrecognised methods (e.g. map — element-wise re-evaluation belongs to a later slice)" do
      expect(fold(receiver: array_of(integer_nominal), method: :map, block: true_const)).to be_nil
    end

    it "declines when receiver shape is unknown (Top/Dynamic — let RBS answer)" do
      expect(fold(receiver: Rigor::Type::Combinator.top, method: :select, block: true_const))
        .to be_nil
    end

    it "treats Constant[1] as truthy and Constant[nil] as falsey for predicate folds" do
      # Block bodies often produce `Constant[1]` (e.g. `x.tap { 1 }`) or `Constant[nil]`; predicate folds should follow
      # Ruby's truthiness semantics, not require literal true/false.
      expect(fold(receiver: array_of(integer_nominal), method: :all?, block: constant_of(1)))
        .to eq(true_const)
      expect(fold(receiver: array_of(integer_nominal), method: :any?, block: constant_of(nil)))
        .to eq(false_const)
    end
  end
end
