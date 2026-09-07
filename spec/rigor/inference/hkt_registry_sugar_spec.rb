# frozen_string_literal: true

require "spec_helper"
require "rigor/inference/hkt_registry"

RSpec.describe Rigor::Inference::HktRegistry do
  describe "Slice 5 sugar syntax" do
    let(:rbs) do
      <<~RBS
        type JSON::value[K] =
            nil | bool | Integer | Float | String
          | Array[JSON::value[K]]
          | Hash[K, JSON::value[K]]
      RBS
    end

    # RSpec/ExampleLength
    # rubocop:disable-next RSpec/ExampleLength
    it "implicitly registers recursive type aliases" do
      buffer = RBS::Buffer.new(name: "test.rbs", content: rbs)
      _dir, _loc, decls = RBS::Parser.parse_signature(buffer)

      loader = Class.new do
        def initialize(decl)
          @decl = decl
        end

        def each_class_decl_annotation; end

        def each_type_alias_decl
          yield [:"JSON::value", Struct.new(:decl).new(@decl)]
        end
      end.new(decls.first)

      registry = described_class.scan_rbs_loader(loader)
      expect(registry).to be_registered(:"JSON::value")

      reg = registry.registration(:"JSON::value")
      expect(reg.arity).to eq(1)
      expect(reg.variance).to eq([:inv])

      defn = registry.definition(:"JSON::value")
      expect(defn.params).to eq([:K])
      expect(defn.body_tree).to be_a(Rigor::Inference::HktBody::Union)

      # Array[JSON::value[K]] -> App[JSON::value, K] inside NominalApp["Array"]
      array_branch = defn.body_tree.arms[5]
      expect(array_branch).to be_a(Rigor::Inference::HktBody::NominalApp)
      expect(array_branch.class_name).to eq("Array")

      app_ref = array_branch.args.first
      expect(app_ref).to be_a(Rigor::Inference::HktBody::AppRef)
      expect(app_ref.uri).to eq(:"JSON::value")
      expect(app_ref.args.first).to be_a(Rigor::Inference::HktBody::Param)
      expect(app_ref.args.first.name).to eq(:K)
    end
  end

  # Regression: issue #776. A recursive alias whose body also contains a subterm the HKT body
  # grammar has no node for (a tuple, record, interface, or unbound variable) drove
  # HktSugarTranslator#fallback_to_type_leaf, which passed a `name_scope:` keyword
  # RbsTypeTranslator.translate does not accept. The ArgumentError escaped the shared
  # `scan_rbs_loader` walk, so `rigor check` on any project whose RBS carried such an alias
  # (every `rbs collection` install does) failed every file with a bogus "internal analyzer error".
  describe "a body arm with no HKT node (issue #776)" do
    let(:rbs) do
      <<~RBS
        type Concerto::tree[T] = T | Array[Concerto::tree[T]] | [T, T]
      RBS
    end

    it "registers the alias instead of raising ArgumentError mid-scan" do
      buffer = RBS::Buffer.new(name: "test.rbs", content: rbs)
      _dir, _loc, decls = RBS::Parser.parse_signature(buffer)

      loader = Class.new do
        def initialize(decl)
          @decl = decl
        end

        def each_class_decl_annotation; end

        def each_type_alias_decl
          yield [:"Concerto::tree", Struct.new(:decl).new(@decl)]
        end
      end.new(decls.first)

      registry = described_class.scan_rbs_loader(loader)

      expect(registry).to be_registered(:"Concerto::tree")

      # The `[T, T]` arm folded to a concrete leaf rather than crashing the walk.
      tuple_arm = registry.definition(:"Concerto::tree").body_tree.arms.last
      expect(tuple_arm).to be_a(Rigor::Inference::HktBody::TypeLeaf)
    end
  end

  # A malformed alias contributes nothing and does not disturb the well-formed aliases in the same
  # walk. It must not raise: an exception in this shared, memoised build is the #776 failure mode
  # (every file becomes a bogus "internal analyzer error").
  describe "a malformed alias in the type-alias walk" do
    it "is skipped without aborting registration of the well-formed aliases" do
      # `Bad::loop` is a zero-arg self-reference on a parameterized alias — `rbs validate` rejects it,
      # and it used to build `AppRef.new(args: [])`, which HktBody rejects (`args must be non-empty`).
      sources = {
        "Bad::loop": "type Bad::loop[T] = Integer | Bad::loop\n",
        "Good::tree": "type Good::tree[T] = T | Array[Good::tree[T]]\n"
      }
      decls = sources.transform_values do |src|
        RBS::Parser.parse_signature(RBS::Buffer.new(name: "test.rbs", content: src))[2].first
      end

      loader = Class.new do
        def initialize(decls)
          @decls = decls
        end

        def each_class_decl_annotation; end

        def each_type_alias_decl
          @decls.each { |name, decl| yield [name, Struct.new(:decl).new(decl)] }
        end
      end.new(decls)

      registry = described_class.scan_rbs_loader(loader)

      expect(registry).not_to be_registered(:"Bad::loop")
      expect(registry).to be_registered(:"Good::tree")
    end
  end
end
