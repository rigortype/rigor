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
end
