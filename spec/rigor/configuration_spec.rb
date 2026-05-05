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

    it "defaults fold_platform_specific_paths to false (platform-agnostic)" do
      Dir.mktmpdir do |dir|
        configuration = described_class.load(File.join(dir, "missing.yml"))
        expect(configuration.fold_platform_specific_paths).to be(false)
      end
    end

    it "reads fold_platform_specific_paths: true to opt into platform-specific path folds" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "fold_platform_specific_paths: true\n")
        configuration = described_class.load(path)
        expect(configuration.fold_platform_specific_paths).to be(true)
      end
    end

    it "accepts plugin entries as bare gem-name strings" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          plugins:
            - rigor-rails
            - rigor-rspec
        YAML

        configuration = described_class.load(path)
        expect(configuration.plugins).to eq(%w[rigor-rails rigor-rspec])
      end
    end

    it "accepts plugin entries as hashes with gem/id/config keys" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          plugins:
            - gem: rigor-rails
              id: rails
              config:
                eager_load: true
        YAML

        configuration = described_class.load(path)
        expect(configuration.plugins).to eq(
          [
            { "gem" => "rigor-rails", "id" => "rails", "config" => { "eager_load" => true } }
          ]
        )
      end
    end

    it "rejects plugin entries that are neither String nor Hash" do
      expect do
        described_class.new(Rigor::Configuration::DEFAULTS.merge("plugins" => [42]))
      end.to raise_error(ArgumentError, /must be a String or Hash/)
    end
  end
end
