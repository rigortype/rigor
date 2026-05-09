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

    it "exposes built-in exclude patterns by default" do
      Dir.mktmpdir do |dir|
        configuration = described_class.load(File.join(dir, "missing.yml"))

        expect(configuration.exclude_patterns).to include(
          "**/vendor/bundle/**",
          "**/.bundle/**",
          "**/node_modules/**"
        )
      end
    end

    it "appends user-supplied exclude patterns to the built-in defaults" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          exclude:
            - "spec/integration/fixtures/**"
            - "examples/*/demo/**"
        YAML

        configuration = described_class.load(path)

        # built-in defaults still present
        expect(configuration.exclude_patterns).to include("**/vendor/bundle/**")
        # user entries appended
        expect(configuration.exclude_patterns).to include(
          "spec/integration/fixtures/**",
          "examples/*/demo/**"
        )
      end
    end

    it "round-trips `exclude:` through #to_h without leaking the built-in defaults" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "exclude: [\"spec/fixtures/**\"]\n")
        configuration = described_class.load(path)

        expect(configuration.to_h["exclude"]).to eq(["spec/fixtures/**"])
      end
    end

    it "reads libraries: as-is and resolves signature_paths: relative to the config file's directory" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "libraries: [csv, set]\nsignature_paths: [sig, vendor/sig]\n")

        configuration = described_class.load(path)
        resolved = [File.join(File.expand_path(dir), "sig"), File.join(File.expand_path(dir), "vendor/sig")]

        expect(configuration.libraries).to eq(%w[csv set])
        expect(configuration.signature_paths).to eq(resolved)
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

    it "reads plugins_io.network and resolves plugins_io.allowed_paths against the config file" do
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
        expect(configuration.plugins_io_allowed_paths).to eq([
                                                               File.join(File.expand_path(dir), "vendor/generated"),
                                                               File.join(File.expand_path(dir), "db/schema.rb")
                                                             ])
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

    it "exposes an empty Configuration::Dependencies by default (ADR-10 slice 1)" do
      Dir.mktmpdir do |dir|
        configuration = described_class.load(File.join(dir, "missing.yml"))

        expect(configuration.dependencies).to be_a(Rigor::Configuration::Dependencies)
        expect(configuration.dependencies.source_inference).to eq([])
      end
    end

    it "reads dependencies.source_inference: from the YAML file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          dependencies:
            source_inference:
              - gem: rack
                mode: full
              - gem: faraday
        YAML
        entries = described_class.load(path).dependencies.source_inference

        expect(entries.length).to eq(2)
        expect(entries[0].gem).to eq("rack")
        expect(entries[0].mode).to eq(:full)
        expect(entries[1].gem).to eq("faraday")
        expect(entries[1].mode).to eq(:when_missing)
      end
    end

    it "round-trips dependencies: through #to_h" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          dependencies:
            source_inference:
              - gem: rack
                mode: full
                roots: [lib, app]
        YAML
        round_tripped = described_class.load(path).to_h["dependencies"]

        expect(round_tripped).to eq(
          "source_inference" => [
            { "gem" => "rack", "mode" => "full", "roots" => %w[lib app] }
          ],
          "budget_per_gem" => Rigor::Configuration::Dependencies::DEFAULT_BUDGET_PER_GEM
        )
      end
    end

    it "surfaces dependencies-section parse errors as ArgumentError at load time" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          dependencies:
            source_inference:
              - mode: full
        YAML

        expect { described_class.load(path) }
          .to raise_error(ArgumentError, /gem must be a non-empty String/)
      end
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

  describe ".discover" do
    it "prefers `.rigor.yml` over `.rigor.dist.yml` when both are present" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write(".rigor.yml", "")
          File.write(".rigor.dist.yml", "")
          expect(described_class.discover).to eq(".rigor.yml")
        end
      end
    end

    it "falls back to `.rigor.dist.yml` when only the dist file is present" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write(".rigor.dist.yml", "")
          expect(described_class.discover).to eq(".rigor.dist.yml")
        end
      end
    end

    it "returns nil when neither candidate is present" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { expect(described_class.discover).to be_nil }
      end
    end
  end

  describe ".load auto-discovery semantics" do
    it "loads `.rigor.yml` exclusively when both files are present (NO implicit merge)" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write(".rigor.yml", "target_ruby: \"3.4\"\n")
          File.write(".rigor.dist.yml", "target_ruby: \"4.0\"\nlibraries: [csv]\n")

          configuration = described_class.load
          expect(configuration.target_ruby).to eq("3.4")
          # `.rigor.dist.yml` is NOT auto-merged — its `libraries:` does not leak in.
          expect(configuration.libraries).to eq([])
        end
      end
    end

    it "uses defaults when neither file is present" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          configuration = described_class.load
          expect(configuration.target_ruby).to eq("4.0")
          expect(configuration.paths).to eq(["lib"])
        end
      end
    end
  end

  describe ".load with `includes:`" do
    it "merges an explicit included file under the current file's keys" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "base.yml"), <<~YAML)
          target_ruby: "3.4"
          libraries: [csv, set]
        YAML
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          includes:
            - base.yml
          target_ruby: "4.0"
        YAML

        configuration = described_class.load(path)
        # current file's `target_ruby` overrides the included one
        expect(configuration.target_ruby).to eq("4.0")
        # the included file's `libraries:` is inherited
        expect(configuration.libraries).to eq(%w[csv set])
      end
    end

    it "resolves paths in an included file relative to that file's directory (PHPStan convention)" do
      Dir.mktmpdir do |dir|
        sub = File.join(dir, "sub")
        FileUtils.mkdir_p(sub)
        File.write(File.join(sub, "shared.yml"), <<~YAML)
          signature_paths:
            - sigs
        YAML
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          includes:
            - sub/shared.yml
        YAML

        configuration = described_class.load(path)
        # `sigs` resolves against `<dir>/sub`, NOT `<dir>`.
        expect(configuration.signature_paths).to eq([File.join(File.expand_path(sub), "sigs")])
      end
    end

    it "supports nested includes" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "level2.yml"), "libraries: [csv]\n")
        File.write(File.join(dir, "level1.yml"), <<~YAML)
          includes:
            - level2.yml
          target_ruby: "3.4"
        YAML
        path = File.join(dir, ".rigor.yml")
        File.write(path, <<~YAML)
          includes:
            - level1.yml
        YAML

        configuration = described_class.load(path)
        expect(configuration.target_ruby).to eq("3.4")
        expect(configuration.libraries).to eq(["csv"])
      end
    end

    it "raises a clear error when an included file does not exist" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "includes: [missing.yml]\n")

        expect { described_class.load(path) }
          .to raise_error(ArgumentError, /include not found.*missing\.yml/)
      end
    end

    it "raises on circular includes" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.yml"), "includes: [b.yml]\n")
        File.write(File.join(dir, "b.yml"), "includes: [a.yml]\n")
        expect { described_class.load(File.join(dir, "a.yml")) }
          .to raise_error(ArgumentError, /circular include/)
      end
    end
  end
end
