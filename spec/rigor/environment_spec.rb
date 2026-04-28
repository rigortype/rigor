# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Rigor::Environment do
  describe ".default" do
    it "memoizes a single shared instance" do
      expect(described_class.default).to equal(described_class.default)
    end

    it "wires the shared core RBS loader" do
      expect(described_class.default.rbs_loader).to equal(Rigor::Environment::RbsLoader.default)
    end
  end

  describe ".new (RBS-blind)" do
    it "produces an environment without an RBS loader" do
      expect(described_class.new.rbs_loader).to be_nil
    end
  end

  describe "#nominal_for_name" do
    let(:env) { described_class.default }

    it "resolves a registry-known class" do
      type = env.nominal_for_name("Integer")
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "falls through to the RBS loader for core-only classes" do
      type = env.nominal_for_name("Encoding::Converter")
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Encoding::Converter")
    end

    it "returns nil when neither registry nor loader knows the name" do
      expect(env.nominal_for_name("ThisClassDoesNotExist123")).to be_nil
    end

    it "returns nil for an RBS-blind environment if the class is not in the registry" do
      blind = described_class.new
      expect(blind.nominal_for_name("Encoding::Converter")).to be_nil
    end
  end

  describe ".for_project" do
    def with_demo_project_root
      Dir.mktmpdir do |tmpdir|
        root = Pathname(tmpdir)
        FileUtils.mkdir_p(root.join("sig"))
        File.write(root.join("sig/sample.rbs"), <<~RBS)
          module DemoFixture
            class Widget
              def name: () -> ::String
            end
          end
        RBS
        yield root
      end
    end

    it "auto-detects sig/ under the given root" do
      with_demo_project_root do |root|
        env = described_class.for_project(root: root)
        expect(env.nominal_for_name("DemoFixture::Widget")&.class_name).to eq("DemoFixture::Widget")
      end
    end

    it "yields an empty signature_paths list when sig/ is absent" do
      Dir.mktmpdir do |empty|
        env = described_class.for_project(root: empty)
        expect(env.rbs_loader.signature_paths).to be_empty
        expect(env.nominal_for_name("Integer")&.class_name).to eq("Integer")
      end
    end

    it "honors explicitly supplied signature_paths" do
      Dir.mktmpdir do |alt|
        FileUtils.mkdir_p(alt)
        File.write(File.join(alt, "alt.rbs"), <<~RBS)
          class AltSampleType
            def thing: () -> ::Integer
          end
        RBS
        env = described_class.for_project(signature_paths: [alt])
        expect(env.nominal_for_name("AltSampleType")&.class_name).to eq("AltSampleType")
      end
    end

    it "loads stdlib libraries when requested" do
      env = described_class.for_project(libraries: ["json"], signature_paths: [])
      expect(env.nominal_for_name("JSON")&.class_name).to eq("JSON")
    end

    it "wires through Scope.empty for type_of queries" do
      require "prism"
      with_demo_project_root do |root|
        env = described_class.for_project(root: root)
        scope = Rigor::Scope.empty(environment: env)
        ast = Prism.parse("DemoFixture::Widget").value
        type = scope.type_of(ast.statements.body.first)
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("DemoFixture::Widget")
      end
    end
  end
end
