# frozen_string_literal: true

require "spec_helper"
require "rigor/cache/rbs_environment_marshal_patch"

# The env cache is written by one process and read by the next, and rbs 4.1 memoises `TypeName#hash` /
# `Namespace#hash` into an `@hash` ivar derived from `Array#hash` / `Symbol#hash` — both seeded PER PROCESS.
# Marshal carries the ivar across verbatim, so without the `_dump` / `_load` hooks a loaded name answers
# `hash` with the writing process's value while an identical freshly-parsed name answers with this one's.
# Nothing raises (the two stay `eql?`); `RBS::Environment#class_decls[TypeName.parse("::String")]` simply
# misses, and every core class reads as unknown on a warm cache.
#
# A same-process `Marshal.load(Marshal.dump(...))` cannot reproduce that — one seed, one answer, which is why
# the cache-hit specs stayed green through the regression. The `foreign_*` helpers stand in for the writing
# process: `.new` bypasses the flyweight interner (so the shared instance is never touched) and the memoised
# `@hash` is set to what a different seed would have produced.
RSpec.describe "RBS name Marshal hooks (rbs_environment_marshal_patch)" do
  # Stands in for the hash another process's seed would have memoised.
  let(:foreign_seed_hash) { 1_234_567_890 }

  def round_trip(object)
    Marshal.load(Marshal.dump(object))
  end

  def foreign_type_name(namespace, name)
    RBS::TypeName.new(namespace: namespace, name: name).tap do |type_name|
      type_name.instance_variable_set(:@hash, foreign_seed_hash)
    end
  end

  def foreign_namespace(path, absolute)
    RBS::Namespace.new(path: path, absolute: absolute).tap do |namespace|
      namespace.instance_variable_set(:@hash, foreign_seed_hash)
    end
  end

  describe "RBS::TypeName" do
    it "answers the same hash as a freshly parsed name after a foreign-seed round trip" do
      loaded = round_trip(foreign_type_name(RBS::Namespace.root, :String))

      expect(loaded).to eq(RBS::TypeName.parse("::String"))
      expect(loaded.hash).to eq(RBS::TypeName.parse("::String").hash)
    end

    it "keeps a Hash keyed by the loaded name addressable by an equal name" do
      table = { round_trip(foreign_type_name(RBS::Namespace.parse("::Foo::"), :Bar)) => :value }

      expect(table[RBS::TypeName.parse("::Foo::Bar")]).to eq(:value)
    end

    it "round-trips through the flyweight interner, so the load is the canonical instance" do
      skip "the flyweight interner arrived in rbs 4.1" unless RbsCoreTypeParams.renamed?

      expect(round_trip(foreign_type_name(RBS::Namespace.root, :String))).to be(RBS::TypeName.parse("::String"))
    end

    it "preserves relative names and the kind derived from the name" do
      %w[Foo ::Foo::Bar ::_Each ::int].each do |source|
        loaded = round_trip(RBS::TypeName.parse(source))
        expect(loaded.to_s).to eq(source)
        expect(loaded.kind).to eq(RBS::TypeName.parse(source).kind)
      end
    end
  end

  describe "RBS::Namespace" do
    it "answers the same hash as a freshly parsed namespace after a foreign-seed round trip" do
      loaded = round_trip(foreign_namespace([:Foo], true))

      expect(loaded).to eq(RBS::Namespace.parse("::Foo::"))
      expect(loaded.hash).to eq(RBS::Namespace.parse("::Foo::").hash)
    end

    it "preserves the root / empty / relative forms" do
      [RBS::Namespace.root, RBS::Namespace.empty, RBS::Namespace.parse("Foo::Bar::")].each do |namespace|
        loaded = round_trip(namespace)
        expect(loaded.path).to eq(namespace.path)
        expect(loaded.absolute?).to eq(namespace.absolute?)
      end
    end
  end
end
