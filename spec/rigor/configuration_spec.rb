# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rigor::Configuration do
  describe ".load" do
    it "loads defaults when the configuration file is absent" do
      Dir.mktmpdir do |dir|
        configuration = described_class.load(File.join(dir, "missing.yml"))

        expect(configuration.target_ruby).to eq("4.0")
        expect(configuration.paths).to eq(["lib"])
        expect(configuration.plugins).to eq([])
        expect(configuration.cache_path).to eq(".rigor/cache")
        expect(configuration.libraries).to eq([])
        expect(configuration.signature_paths).to be_nil
      end
    end

    it "reads libraries: and signature_paths: from the YAML file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          libraries:
            - csv
            - set
          signature_paths:
            - sig
            - vendor/sig
        YAML

        configuration = described_class.load(path)

        expect(configuration.libraries).to eq(%w[csv set])
        expect(configuration.signature_paths).to eq(%w[sig vendor/sig])
      end
    end

    it "treats signature_paths: [] as 'load no project signatures'" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "signature_paths: []\n")

        configuration = described_class.load(path)

        expect(configuration.signature_paths).to eq([])
      end
    end
  end
end
