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

    it "accepts target_ruby in `<major>.<minor>` and `<major>.<minor>.<patch>` forms" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "target_ruby: \"3.4\"\n")
        expect(described_class.load(path).target_ruby).to eq("3.4")

        File.write(path, "target_ruby: \"3.4.1\"\n")
        expect(described_class.load(path).target_ruby).to eq("3.4.1")

        File.write(path, "target_ruby: latest\n")
        expect(described_class.load(path).target_ruby).to eq("latest")
      end
    end

    it "rejects target_ruby values that are not version-shaped or `latest`" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "target_ruby: stable\n")
        expect { described_class.load(path) }.to raise_error(ArgumentError, /target_ruby/)

        File.write(path, "target_ruby: \"3\"\n")
        expect { described_class.load(path) }.to raise_error(ArgumentError, /target_ruby/)
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

    it "defaults plugins_io.network to :disabled and allowed_paths to []" do
      Dir.mktmpdir do |dir|
        configuration = described_class.load(File.join(dir, "missing.yml"))
        expect(configuration.plugins_io_network).to eq(:disabled)
        expect(configuration.plugins_io_allowed_paths).to eq([])
      end
    end

    it "reads plugins_io.network and plugins_io.allowed_paths from the YAML file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          plugins_io:
            network: disabled
            allowed_paths:
              - vendor/generated
              - db/schema.rb
        YAML

        configuration = described_class.load(path)
        expect(configuration.plugins_io_network).to eq(:disabled)
        expect(configuration.plugins_io_allowed_paths).to eq(%w[vendor/generated db/schema.rb])
      end
    end

    it "defaults severity_profile to :balanced" do
      Dir.mktmpdir do |dir|
        configuration = described_class.load(File.join(dir, "missing.yml"))
        expect(configuration.severity_profile).to eq(:balanced)
        expect(configuration.severity_overrides).to eq({})
      end
    end

    it "reads severity_profile + severity_overrides from the YAML file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        # NOTE: `off` is reserved in YAML 1.1 (parses to `false`),
        # so users quote `"off"` when they want the severity. The
        # config loader does NOT auto-coerce booleans.
        File.write(path, <<~YAML)
          severity_profile: strict
          severity_overrides:
            call.argument-type-mismatch: warning
            dump: "off"
        YAML

        configuration = described_class.load(path)
        expect(configuration.severity_profile).to eq(:strict)
        expect(configuration.severity_overrides).to eq(
          "call.argument-type-mismatch" => :warning,
          "dump" => :off
        )
      end
    end

    it "rejects unknown severity_profile values" do
      expect do
        described_class.new(
          Rigor::Configuration::DEFAULTS.merge("severity_profile" => "nonsense")
        )
      end.to raise_error(ArgumentError, /severity_profile/)
    end

    it "rejects severity_overrides values outside the recognised set" do
      expect do
        described_class.new(
          Rigor::Configuration::DEFAULTS.merge(
            "severity_overrides" => { "call.undefined-method" => "noisy" }
          )
        )
      end.to raise_error(ArgumentError, /must be one of/)
    end

    it "rejects plugins_io.network values other than :disabled in slice 2" do
      expect do
        described_class.new(
          Rigor::Configuration::DEFAULTS.merge(
            "plugins_io" => { "network" => "allowed", "allowed_paths" => [] }
          )
        )
      end.to raise_error(ArgumentError, /plugins_io\.network/)
    end
  end
end
