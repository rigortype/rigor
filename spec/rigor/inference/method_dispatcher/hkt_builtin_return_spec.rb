# frozen_string_literal: true

require "spec_helper"

# ADR-20 slice 3 end-to-end check: `JSON.parse(...)` dispatched
# through the top-level `MethodDispatcher.dispatch` returns the
# reduced HKT type instead of the upstream rbs gem's `untyped`
# slot.
RSpec.describe Rigor::Inference::MethodDispatcher do # rubocop:disable RSpec/SpecFilePathFormat
  let(:environment) { Rigor::Environment.default }
  let(:json_singleton) { Rigor::Type::Combinator.singleton_of(JSON) }

  def dispatch(method_name)
    described_class.dispatch(
      receiver_type: json_singleton,
      method_name: method_name,
      arg_types: [Rigor::Type::Combinator.nominal_of(String)],
      environment: environment
    )
  end

  describe "HKT-builtin return-type tier (JSON.parse)" do
    it "returns a non-Top type for JSON.parse" do
      type = dispatch(:parse)
      expect(type).not_to be_nil
      expect(type).not_to eq(Rigor::Type::Combinator.untyped)
    end

    it "returns the reduced json::value union (not the opaque App carrier)" do
      type = dispatch(:parse)
      expect(type).to be_a(Rigor::Type::Union)
    end

    it "the union includes the leaf JSON atoms (nil / true / false / Integer / Float / String)" do
      type = dispatch(:parse)
      described_atoms = type.members.map(&:describe)
      expect(described_atoms).to include("nil", "true", "false", "Integer", "Float", "String")
    end

    it "the union includes Array[json::value[String]] with the recursive self-ref" do
      type = dispatch(:parse)
      array_arm = type.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Array" }
      expect(array_arm).not_to be_nil
      nested = array_arm.type_args.first
      expect(nested).to be_a(Rigor::Type::App)
      expect(nested.uri).to eq(:"json::value")
      expect(nested.args).to eq([Rigor::Type::Combinator.nominal_of(String)])
    end

    it "the union includes Hash[String, json::value[String]] with the recursive self-ref" do
      type = dispatch(:parse)
      hash_arm = type.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Hash" }
      expect(hash_arm).not_to be_nil
      expect(hash_arm.type_args[0]).to eq(Rigor::Type::Combinator.nominal_of(String))
      nested = hash_arm.type_args[1]
      expect(nested).to be_a(Rigor::Type::App)
      expect(nested.uri).to eq(:"json::value")
    end

    it "also fires for JSON.parse!" do
      type = dispatch(:parse!)
      expect(type).to be_a(Rigor::Type::Union)
    end

    it "also fires for JSON.load" do
      type = dispatch(:load)
      expect(type).to be_a(Rigor::Type::Union)
    end

    context "with the `symbolize_names: true` discriminator" do
      def dispatch_with_opts(method_name, opts_pairs)
        opts_shape = Rigor::Type::HashShape.new(opts_pairs)
        described_class.dispatch(
          receiver_type: json_singleton,
          method_name: method_name,
          arg_types: [Rigor::Type::Combinator.nominal_of(String), opts_shape],
          environment: environment
        )
      end

      it "switches K = Symbol when arg_types[1] carries `symbolize_names: true`" do
        type = dispatch_with_opts(:parse, { symbolize_names: Rigor::Type::Constant.new(true) })
        hash_arm = type.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Hash" }
        expect(hash_arm).not_to be_nil
        expect(hash_arm.type_args[0]).to eq(Rigor::Type::Combinator.nominal_of(Symbol))
        nested = hash_arm.type_args[1]
        expect(nested).to be_a(Rigor::Type::App)
        expect(nested.args).to eq([Rigor::Type::Combinator.nominal_of(Symbol)])
      end

      it "stays at K = String when `symbolize_names: false`" do
        type = dispatch_with_opts(:parse, { symbolize_names: Rigor::Type::Constant.new(false) })
        hash_arm = type.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Hash" }
        expect(hash_arm.type_args[0]).to eq(Rigor::Type::Combinator.nominal_of(String))
      end

      it "stays at K = String when `symbolize_names` is absent" do
        type = dispatch_with_opts(:parse, { max_nesting: Rigor::Type::Constant.new(10) })
        hash_arm = type.members.find { |t| t.is_a?(Rigor::Type::Nominal) && t.class_name == "Hash" }
        expect(hash_arm.type_args[0]).to eq(Rigor::Type::Combinator.nominal_of(String))
      end
    end

    it "does not fire for a JSON instance-method (only Singleton receivers)" do
      type = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.nominal_of(JSON),
        method_name: :parse,
        arg_types: [Rigor::Type::Combinator.nominal_of(String)],
        environment: environment
      )
      # The instance-side path falls through to standard dispatch (RBS or
      # user-class fallback). Whatever it returns, it MUST NOT be the
      # singleton-side reduced Union.
      expect(type).not_to be_a(Rigor::Type::Union)
    end

    it "also fires for YAML.safe_load" do
      type = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.singleton_of(YAML),
        method_name: :safe_load,
        arg_types: [Rigor::Type::Combinator.nominal_of(String)],
        environment: environment
      )
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members.map(&:describe)).to include("nil", "true", "Integer", "String")
    end

    it "also fires for YAML.safe_load_file" do
      type = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.singleton_of(YAML),
        method_name: :safe_load_file,
        arg_types: [Rigor::Type::Combinator.nominal_of(String)],
        environment: environment
      )
      expect(type).to be_a(Rigor::Type::Union)
    end

    it "also fires for Psych.safe_load" do
      type = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.singleton_of(Psych),
        method_name: :safe_load,
        arg_types: [Rigor::Type::Combinator.nominal_of(String)],
        environment: environment
      )
      expect(type).to be_a(Rigor::Type::Union)
    end

    it "does not fire for YAML.load (deliberately uncovered — can return any Ruby object)" do
      type = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.singleton_of(YAML),
        method_name: :load,
        arg_types: [Rigor::Type::Combinator.nominal_of(String)],
        environment: environment
      )
      next if type.nil?

      next unless type.is_a?(Rigor::Type::Union)

      nominal_class_names = type.members.grep(Rigor::Type::Nominal).map(&:class_name)
      # Should NOT be the json::value Union shape (which contains BOTH Array AND Hash arms).
      json_value_shape = nominal_class_names.include?("Array") && nominal_class_names.include?("Hash")
      expect(json_value_shape).to be(false)
    end

    it "does not fire for an unrelated singleton (e.g. YAML.parse)" do
      type = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.singleton_of(YAML),
        method_name: :parse,
        arg_types: [Rigor::Type::Combinator.nominal_of(String)],
        environment: environment
      )
      # YAML.parse is NOT in METHOD_RETURN_OVERRIDES; the dispatcher
      # falls through to RBS / whatever else and the result MUST NOT be
      # the json::value Union shape.
      next if type.nil?

      if type.is_a?(Rigor::Type::Union)
        nominal_arms = type.members.grep(Rigor::Type::Nominal)
        expect(nominal_arms.map(&:class_name)).not_to include("Array", "Hash")
      end
    end
  end
end
