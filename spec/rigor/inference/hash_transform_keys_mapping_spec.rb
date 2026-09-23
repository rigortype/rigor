# frozen_string_literal: true

require "spec_helper"

# `Hash#transform_keys(mapping)` renames each key the mapping names to that key's mapping value; only the keys
# the mapping misses reach the block, or stay as they are when there is no block. The dispatcher took the new
# key type from the block alone: rbs 4.2's `[K2] (hash[_Key, K2]) { (K) -> K2 } -> Hash[K2, V]` is solved with
# `K2` bound from the block return, and rbs 3.10 declares no mapping overload at all. A key the mapping produced
# therefore read as impossible, and a comparison against it folded always-falsey on correct code.
#
# Every example that moves is paired with a block-only control that must not.
RSpec.describe "Hash#transform_keys with a mapping argument", type: :runner do
  def dumped_types(source, sig: {})
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig)
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  # Every error-severity rule plus the always-truthy / always-falsey family. On rbs 3.10 the examples that pass
  # a plain positional mapping also see `call.wrong-arity`: that line's declaration has no mapping overload, and
  # the arity rule reads the declaration rather than the dispatcher's answer. CI runs this file on rbs 4.x only.
  def reported_rules(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.rule if diagnostic.severity == :error || diagnostic.rule.to_s.start_with?("flow.")
    end
  end

  # Nominal receivers and mappings, so the answer is read off `Hash[K, V]` type arguments rather than a shape.
  let(:store_sig) do
    { "store.rbs" => <<~RBS }
      class Store
        def self.counts: () -> Hash[Symbol, Integer]
        def self.renames: () -> Hash[Symbol, String]
      end
    RBS
  end

  describe "a literal receiver" do
    it "adds the mapping's values to the block's keys" do
      # Runtime `{ z: 1, b: 2 }` and `{ z: 1, "b" => 2 }`.
      expect(dumped_types(<<~RUBY)).to eq(["Hash[:a | :b | :z, 1 | 2]", 'Hash["a" | "b" | :z, 1 | 2]'])
        dump_type({ a: 1, b: 2 }.transform_keys({ a: :z }) { |k| k })
        dump_type({ a: 1, b: 2 }.transform_keys({ a: :z }, &:to_s))
      RUBY
    end

    it "no longer folds a comparison with a renamed key always-falsey" do
      # THE REPORTED HAZARD: `r.keys` read `:a | :b`, so `== :z` folded to false.
      expect(reported_rules(<<~RUBY)).to be_empty
        r = { a: 1, b: 2 }.transform_keys({ a: :z }) { |k| k }
        puts "z first" if r.keys.first == :z
      RUBY
    end

    it "keeps the receiver's keys beside the mapping's values when there is no block" do
      # Runtime `{ z: 1, b: 2 }`. rbs 4.2 answered `Hash[:a | :b | Dynamic[top], 1 | 2]` (`K2` unbound), rbs 3.10
      # an `Enumerator`.
      expect(dumped_types(<<~RUBY)).to eq(["Hash[:a | :b | :z, 1 | 2]"])
        dump_type({ a: 1, b: 2 }.transform_keys({ a: :z }))
      RUBY
    end

    it "still folds a block-only transform_keys" do
      expect(dumped_types(<<~RUBY)).to eq(['{ "a": 1, "b": 2 }'])
        dump_type({ a: 1, b: 2 }.transform_keys { |k| k.to_s })
      RUBY
    end
  end

  describe "a nominal receiver" do
    it "adds the mapping's value type to the block's key type" do
      expect(dumped_types(<<~RUBY, sig: store_sig)).to eq(["Hash[Integer | String, Integer]"])
        dump_type(Store.counts.transform_keys(Store.renames) { |k| k.size })
      RUBY
    end

    it "keeps the block-only answer" do
      expect(dumped_types(<<~RUBY, sig: store_sig)).to eq(["Hash[Integer, Integer]"])
        dump_type(Store.counts.transform_keys { |k| k.size })
      RUBY
    end
  end

  describe "an argument the analysis cannot read" do
    it "adds a Dynamic[top] key arm for a mapping whose values are unknown" do
      expect(dumped_types(<<~RUBY)).to eq(['Hash["a" | Dynamic[top], 1]'])
        def rename(mapping)
          dump_type({ a: 1 }.transform_keys(mapping) { |k| k.to_s })
        end
      RUBY
    end

    it "keeps the mapping beside a block-pass it cannot read" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[:z | Dynamic[top], 1]"])
        def rename(blk)
          dump_type({ a: 1 }.transform_keys({ a: :z }, &blk))
        end
      RUBY
    end
  end

  # The blockless form answered `Hash[K | Dynamic[top], V]` before, so a mapping typed narrower than its
  # runtime value is a new way for a comparison to fold. Each of these is correct code and reports nothing.
  describe "a mapping typed narrower than its runtime value" do
    # `{ **o, b: :y }` typed `Hash[:b, :y]` until the literal joined its splatted entries, and the tier carried a
    # `Dynamic[top]` arm for a splatted literal written as the argument. The literal's own type now lists `:z`,
    # however it reaches the call.
    it "reads a literal with a **splat entry by its own type" do
      # Runtime `{ z: 1, y: 2, c: 3 }` each time; `send` reaches the tier with the `send` node, whose first
      # argument is the method name.
      expect(dumped_types(<<~RUBY)).to eq(["Hash[:a | :b | :c | :y | :z, 1 | 2 | 3]"] * 3)
        H = { a: 1, b: 2, c: 3 }
        o = { a: :z }
        dump_type(H.transform_keys(**o, b: :y))
        dump_type(H.send(:transform_keys, { **o, b: :y }))
        m = { **o, b: :y }
        dump_type(H.transform_keys(m))
      RUBY
    end

    it "does not fold a comparison with a key the splatted mapping renames to" do
      expect(reported_rules(<<~RUBY)).to be_empty
        H = { a: 1, b: 2, c: 3 }
        o = { a: :z }
        r = H.transform_keys(**o, b: :y)
        puts "z" if r.keys.first == :z
        m = { **o, b: :y }
        s = H.send(:transform_keys, m)
        puts "z" if s.keys.first == :z
      RUBY
    end

    it "does not trust an empty mapping filled through an alias" do
      # Runtime `{ z: 1, b: 2 }`; the engine records no aliasing, so `m` still reads `{}`.
      expect(reported_rules(<<~RUBY)).to be_empty
        m = {}
        m.tap { |x| x[:a] = :z }
        r = { a: 1, b: 2 }.transform_keys(m)
        puts "z" if r.keys.first == :z
      RUBY
    end
  end

  describe "a splatted argument with a block" do
    it "adds a Dynamic[top] key arm instead of the block-only answer" do
      # Runtime `{ z: 1, "b" => 2 }`; the RBS answer was `Hash["a" | "b", 1 | 2]`.
      expect(reported_rules(<<~RUBY)).to be_empty
        xs = [{ a: :z }]
        r = { a: 1, b: 2 }.transform_keys(*xs) { |k| k.to_s }
        puts "z" if r.keys.first == :z
      RUBY
    end
  end
end
