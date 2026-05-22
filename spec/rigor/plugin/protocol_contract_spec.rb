# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::ProtocolContract do
  def build(**overrides)
    described_class.new(path_glob: "lib/controller/**/*.rb",
                        method_name: :get,
                        param_types: [{ index: 0, type_name: "Rack::Request" }],
                        return_type_name: "Rack::Response", **overrides)
  end

  describe "construction" do
    it "stores the declared fields" do
      contract = build
      expect(contract.path_glob).to eq("lib/controller/**/*.rb")
      expect(contract.method_name).to eq(:get)
      expect(contract.return_type_name).to eq("Rack::Response")
      expect(contract.singleton).to be(false)
      expect(contract.severity).to eq(:error)
    end

    it "coerces param_types hashes into ParamType data objects" do
      contract = build
      expect(contract.param_types.size).to eq(1)
      param = contract.param_types.first
      expect(param).to be_a(described_class::ParamType)
      expect(param.index).to eq(0)
      expect(param.type_name).to eq("Rack::Request")
    end

    it "coerces a String method_name to a Symbol" do
      expect(build(method_name: "get").method_name).to eq(:get)
    end

    it "defaults param_types to empty and singleton to false" do
      contract = described_class.new(
        path_glob: "lib/**/*.rb", method_name: :call, return_type_name: "Object"
      )
      expect(contract.param_types).to eq([])
      expect(contract.singleton).to be(false)
    end

    it "accepts nil return_type_name (void protocol — skip return check)" do
      contract = described_class.new(
        path_glob: "app/actions/**/*.rb",
        method_name: :handle,
        param_types: [{ index: 0, type_name: "Hanami::Action::Request" }]
      )
      expect(contract.return_type_name).to be_nil
    end

    it "freezes the contract after construction" do
      expect(build).to be_frozen
    end

    it "is Ractor.shareable? at construction (ADR-15 Phase 1)" do
      expect(Ractor.shareable?(build)).to be(true)
    end
  end

  describe "validation" do
    it "rejects an empty path_glob" do
      expect { build(path_glob: "") }.to raise_error(ArgumentError, /path_glob/)
    end

    it "rejects a non-String non-nil return_type_name" do
      expect { build(return_type_name: :Response) }.to raise_error(ArgumentError, /return_type_name/)
    end

    it "rejects a severity outside the allowed set" do
      expect { build(severity: :fatal) }.to raise_error(ArgumentError, /severity/)
    end

    it "rejects a param_types entry without a valid index" do
      expect do
        build(param_types: [{ index: -1, type_name: "Rack::Request" }])
      end.to raise_error(ArgumentError, /param_types/)
    end

    it "rejects a param_types entry without a type_name" do
      expect do
        build(param_types: [{ index: 0, type_name: "" }])
      end.to raise_error(ArgumentError, /param_types/)
    end

    it "rejects a non-Array param_types argument" do
      expect { build(param_types: {}) }.to raise_error(ArgumentError, /param_types/)
    end
  end

  describe "#with_path_glob" do
    it "returns a copy with the glob replaced and all other fields preserved" do
      replaced = build.with_path_glob("app/controllers/**/*.rb")
      expect(replaced.path_glob).to eq("app/controllers/**/*.rb")
      expect(replaced.method_name).to eq(:get)
      expect(replaced.return_type_name).to eq("Rack::Response")
      expect(replaced.param_types.first.type_name).to eq("Rack::Request")
    end

    it "does not mutate the receiver" do
      original = build
      original.with_path_glob("other/**/*.rb")
      expect(original.path_glob).to eq("lib/controller/**/*.rb")
    end
  end

  describe "#to_h and equality" do
    it "renders a stable Hash for cache-key inclusion" do
      expect(build.to_h).to eq(
        "path_glob" => "lib/controller/**/*.rb",
        "method_name" => "get",
        "singleton" => false,
        "param_types" => [{ "index" => 0, "type_name" => "Rack::Request" }],
        "return_type_name" => "Rack::Response",
        "severity" => "error"
      )
    end

    it "treats contracts with the same fields as equal" do
      one = build
      another = build
      expect(one).to eq(another)
      expect(one.hash).to eq(another.hash)
    end

    it "differs when the path_glob differs" do
      expect(build).not_to eq(build(path_glob: "app/**/*.rb"))
    end
  end
end
