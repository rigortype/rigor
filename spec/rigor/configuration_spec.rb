# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rigor::Configuration do
  describe ".load" do
    # The ADR-93 WD2 auto-wire is pinned off suite-wide in spec_helper (untagged examples), so these unit
    # examples assert the YAML→config coercion mechanics without the injected `rigor-rbs-inline` entry; the
    # auto-wire itself is exercised in its own `:rbs_inline_autowire` describe block below.
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
            - gem: rigor-activerecord
              id: activerecord
              config:
                eager_load: true
        YAML

        configuration = described_class.load(path)
        expect(configuration.plugins).to eq(
          [
            { "gem" => "rigor-activerecord", "id" => "activerecord", "config" => { "eager_load" => true } }
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
        # NOTE: `off` is reserved in YAML 1.1 (parses to `false`), so users quote `"off"` when they want the severity.
        # The config loader does NOT auto-coerce booleans.
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

    it "gives a friendly error when a severity is an unquoted YAML boolean" do
      # `off` is YAML 1.1-reserved and parses to `false`; the user almost certainly meant the severity string "off".
      expect do
        described_class.new(
          Rigor::Configuration::DEFAULTS.merge(
            "severity_overrides" => { "flow.dead-assignment" => false }
          )
        )
      end.to raise_error(
        ArgumentError,
        /severity_overrides\["flow\.dead-assignment"\].*did you mean the string "off".*quote the severity/m
      )
    end

    it "accepts the quoted \"off\" severity" do
      configuration = described_class.new(
        Rigor::Configuration::DEFAULTS.merge(
          "severity_overrides" => { "flow.dead-assignment" => "off" }
        )
      )
      expect(configuration.severity_overrides).to eq("flow.dead-assignment" => :off)
    end

    # ADR-50 § WD2 — the `bleeding_edge:` overlay selector.
    describe "bleeding_edge:" do
      def config_with(value)
        described_class.new(Rigor::Configuration::DEFAULTS.merge("bleeding_edge" => value))
      end

      # A queued change that moves no severity — stubbed in rather than added to the shipped registry, which
      # carries only what is actually queued for the next major.
      let(:behaviour_feature) do
        Rigor::BleedingEdge::Feature.new(id: "feat-b", summary: "count differently", kind: :behaviour)
      end

      it "defaults to adopting nothing, with an empty severity map" do
        Dir.mktmpdir do |dir|
          configuration = described_class.load(File.join(dir, "missing.yml"))
          expect(configuration.bleeding_edge).to eq("mode" => "none")
          expect(configuration.bleeding_edge_severity_overrides).to eq({})
        end
      end

      it "normalizes each accepted form" do
        expect(config_with(false).bleeding_edge).to eq("mode" => "none")
        expect(config_with(true).bleeding_edge).to eq("mode" => "all")
        expect(config_with(%w[a b]).bleeding_edge).to eq("mode" => "list", "ids" => %w[a b])
        expect(config_with("all" => true, "except" => ["a"]).bleeding_edge)
          .to eq("mode" => "all", "except" => ["a"])
        expect(config_with("all" => false).bleeding_edge).to eq("mode" => "none")
      end

      it "round-trips through #to_h in the user-facing form" do
        expect(config_with(false).to_h["bleeding_edge"]).to be(false)
        expect(config_with(true).to_h["bleeding_edge"]).to be(true)
        expect(config_with(%w[a b]).to_h["bleeding_edge"]).to eq(%w[a b])
        expect(config_with("all" => true, "except" => ["a"]).to_h["bleeding_edge"])
          .to eq("all" => true, "except" => ["a"])
      end

      it "rejects a value that is not a boolean, list, or hash" do
        expect { config_with(42) }.to raise_error(ArgumentError, /bleeding_edge must be/)
      end

      it "reads the selector from the YAML file" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, ".rigor.yml")
          File.write(path, "bleeding_edge:\n  - some-feature\n")
          expect(described_class.load(path).bleeding_edge).to eq("mode" => "list", "ids" => ["some-feature"])
        end
      end

      it "stays Ractor.shareable? for every form (frozen ids for the list paths)" do
        expect(Ractor.shareable?(config_with(true))).to be(true)
        expect(Ractor.shareable?(config_with(%w[a b]))).to be(true)
        expect(Ractor.shareable?(config_with("all" => true, "except" => ["x"]))).to be(true)
      end

      # ADR-50 § WD2 — the CLI mirror (`--bleeding-edge[=ids]`) overrides the configured selection for a single run via
      # this method.
      describe "#with_bleeding_edge" do
        let(:base) { config_with(false) }

        it "returns a sibling whose selection (and derived severity map) is replaced" do
          expect(base.with_bleeding_edge(true).bleeding_edge).to eq("mode" => "all")
          expect(base.with_bleeding_edge(%w[a b]).bleeding_edge).to eq("mode" => "list", "ids" => %w[a b])
          expect(base.with_bleeding_edge(false).bleeding_edge).to eq("mode" => "none")
        end

        it "recomputes bleeding_edge_severity_overrides from the new selector" do
          # The wiring, not the shipped overlay's content, is what this pins: adopting everything must yield the
          # overlay's severity map, and adopting nothing must yield an empty one.
          expect(base.bleeding_edge_severity_overrides).to eq({})
          expect(base.with_bleeding_edge(true).bleeding_edge_severity_overrides)
            .to eq(Rigor::BleedingEdge.severity_overrides_for("mode" => "all"))
          expect(base.with_bleeding_edge(false).bleeding_edge_severity_overrides).to eq({})
        end

        it "leaves the receiver untouched and returns a frozen, shareable config" do
          result = base.with_bleeding_edge(true)
          expect(base.bleeding_edge).to eq("mode" => "none")
          expect(result).to be_frozen
          expect(Ractor.shareable?(result)).to be(true)
        end

        it "shares every other field with the receiver" do
          result = base.with_bleeding_edge(true)
          expect(result.paths).to equal(base.paths)
          expect(result.severity_profile).to eq(base.severity_profile)
        end

        # The regression this guards: `#with_bleeding_edge` re-sets ivars by hand, so an ivar `#initialize`
        # derives from the selector and this method forgets is stale — and `--bleeding-edge` would then flip the
        # severity map while leaving every behaviour feature reading its *configured* value.
        it "recomputes the active-id set the behaviour predicate reads" do
          stub_const("Rigor::BleedingEdge::FEATURES", [behaviour_feature].freeze)
          config = config_with(false)

          expect(config.bleeding_edge_active?("feat-b")).to be(false)
          expect(config.with_bleeding_edge(true).bleeding_edge_active?("feat-b")).to be(true)
          expect(config.with_bleeding_edge(%w[feat-b]).bleeding_edge_active?("feat-b")).to be(true)
          expect(config.with_bleeding_edge("all" => true, "except" => %w[feat-b])
                       .bleeding_edge_active?("feat-b")).to be(false)
          expect(config.with_bleeding_edge(true).with_bleeding_edge(false).bleeding_edge_active?("feat-b"))
            .to be(false)
        end
      end

      # ADR-50 § WD2 — how a *behaviour* feature (one that moves no severity) reaches its call site.
      describe "#bleeding_edge_active?" do
        before { stub_const("Rigor::BleedingEdge::FEATURES", [behaviour_feature].freeze) }

        it "answers per selector form" do
          expect(config_with(false).bleeding_edge_active?("feat-b")).to be(false)
          expect(config_with(true).bleeding_edge_active?("feat-b")).to be(true)
          expect(config_with(%w[feat-b]).bleeding_edge_active?("feat-b")).to be(true)
          expect(config_with(%w[other]).bleeding_edge_active?("feat-b")).to be(false)
          expect(config_with("all" => true, "except" => %w[feat-b]).bleeding_edge_active?("feat-b")).to be(false)
          expect(config_with("all" => true, "except" => %w[other]).bleeding_edge_active?("feat-b")).to be(true)
        end

        # An unknown id in a *config file* is inert (it may come from a newer gem); an unknown id at the query
        # is a contributor's typo against the registry in this same checkout, and must not read as `false`.
        it "raises on an id no known feature carries, while the config keeps ignoring one" do
          expect { config_with(true).bleeding_edge_active?("ghost") }
            .to raise_error(ArgumentError, /unknown bleeding-edge feature id "ghost"/)
          expect(config_with(%w[ghost]).bleeding_edge).to eq("mode" => "list", "ids" => %w[ghost])
          expect(config_with(%w[ghost]).bleeding_edge_severity_overrides).to eq({})
        end

        # ADR-50 § WD7 — graduation moves the id out of FEATURES; the behaviour is then on for everyone, so a
        # call site that still asks keeps it rather than silently reverting.
        it "answers true for a graduated id whatever the configuration selects" do
          stub_const("Rigor::BleedingEdge::GRADUATED", ["feat-g"].freeze)
          expect(config_with(false).bleeding_edge_active?("feat-g")).to be(true)
          expect(config_with(%w[feat-b]).bleeding_edge_active?("feat-g")).to be(true)
          expect(config_with("all" => true, "except" => %w[feat-g]).bleeding_edge_active?("feat-g")).to be(true)
        end
      end
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

    it "round-trips dependencies: through #to_h" do
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
          "budget_per_gem" => Rigor::Configuration::Dependencies::DEFAULT_BUDGET_PER_GEM,
          "budget_overrun_strategy" => Rigor::Configuration::Dependencies::DEFAULT_BUDGET_OVERRUN_STRATEGY.to_s
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

  # ADR-93 WD2 — the bundled `rigor-rbs-inline` plugin is default-wired from `.load` (the real-project route),
  # in WD1's annotation-gated, magic-comment-free mode, when the upstream `rbs-inline` library is resolvable
  # and the user has not already listed it. A bare `Configuration.new` never auto-wires.
  describe ".load auto-wiring rigor-rbs-inline (ADR-93 WD2)", :rbs_inline_autowire do
    def load_with_config(dir, yaml)
      path = File.join(dir, ".rigor.yml")
      File.write(path, yaml)
      described_class.load(path)
    end

    context "when the upstream rbs-inline library is resolvable" do
      before { allow(described_class).to receive(:rbs_inline_library_resolvable?).and_return(true) }

      it "injects the plugin with require_magic_comment: false when the user lists no plugins" do
        Dir.mktmpdir do |dir|
          configuration = described_class.load(File.join(dir, "missing.yml"))
          expect(configuration.plugins).to eq(
            [{ "gem" => "rigor-rbs-inline", "id" => "rbs-inline",
               "config" => { "require_magic_comment" => false } }]
          )
        end
      end

      it "appends the auto-wired entry after the user's own plugins" do
        Dir.mktmpdir do |dir|
          configuration = load_with_config(dir, "plugins:\n  - rigor-rails\n")
          expect(configuration.plugins).to eq(
            ["rigor-rails",
             { "gem" => "rigor-rbs-inline", "id" => "rbs-inline",
               "config" => { "require_magic_comment" => false } }]
          )
        end
      end

      it "does not double-wire when the user already lists the gem" do
        Dir.mktmpdir do |dir|
          configuration = load_with_config(dir, "plugins:\n  - rigor-rbs-inline\n")
          expect(configuration.plugins).to eq(["rigor-rbs-inline"])
        end
      end

      it "does not double-wire when the user lists it by manifest id" do
        Dir.mktmpdir do |dir|
          configuration = load_with_config(dir, "plugins:\n  - gem: rigor-rbs-inline\n    id: rbs-inline\n")
          expect(configuration.plugins).to eq(
            [{ "gem" => "rigor-rbs-inline", "id" => "rbs-inline" }]
          )
        end
      end

      it "leaves an explicit enabled: false opt-out entry in place for the loader to skip" do
        Dir.mktmpdir do |dir|
          configuration = load_with_config(dir, "plugins:\n  - gem: rigor-rbs-inline\n    enabled: false\n")
          expect(configuration.plugins).to eq(
            [{ "gem" => "rigor-rbs-inline", "enabled" => false }]
          )
        end
      end
    end

    context "when the upstream rbs-inline library is not resolvable (standalone, WD3)" do
      before { allow(described_class).to receive(:rbs_inline_library_resolvable?).and_return(false) }

      it "does not auto-wire the plugin" do
        Dir.mktmpdir do |dir|
          configuration = described_class.load(File.join(dir, "missing.yml"))
          expect(configuration.plugins).to eq([])
        end
      end
    end

    it "never auto-wires from a bare Configuration.new" do
      expect(described_class.new.plugins).to eq([])
    end
  end

  describe "parallel.workers (ADR-15 Phase 4c)" do
    it "defaults to 0 when the config is unspecified" do
      expect(described_class.new.parallel_workers).to eq(0)
    end

    it "reads `parallel.workers:` from .rigor.yml" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "parallel:\n  workers: 4\n")
        expect(described_class.load(path).parallel_workers).to eq(4)
      end
    end

    it "round-trips through to_h" do
      configuration = described_class.new(
        Rigor::Configuration::DEFAULTS.merge("parallel" => { "workers" => 6 })
      )
      expect(configuration.to_h.fetch("parallel")).to eq("workers" => 6)
    end

    it "raises a useful error when `parallel.workers:` is non-numeric" do
      expect do
        described_class.new(
          Rigor::Configuration::DEFAULTS.merge("parallel" => { "workers" => "many" })
        )
      end.to raise_error(ArgumentError, /parallel\.workers/)
    end

    it "raises when `parallel.workers:` is negative" do
      expect do
        described_class.new(
          Rigor::Configuration::DEFAULTS.merge("parallel" => { "workers" => -1 })
        )
      end.to raise_error(ArgumentError, /parallel\.workers must be >= 0/)
    end
  end

  describe "pre_eval glob expansion (ADR-17 slice 4)" do
    it "expands a `**/*.rb` glob to the matching files" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "core_ext"))
        File.write(File.join(dir, "lib", "core_ext", "string_ext.rb"), "class String; end\n")
        File.write(File.join(dir, "lib", "core_ext", "hash_ext.rb"), "class Hash; end\n")
        config_path = File.join(dir, ".rigor.yml")
        File.write(config_path, "pre_eval:\n  - lib/core_ext/**/*.rb\n")
        configuration = described_class.load(config_path)
        expect(configuration.pre_eval.map { |p| File.basename(p) }).to contain_exactly(
          "string_ext.rb", "hash_ext.rb"
        )
      end
    end

    it "preserves literal entries that contain no glob meta characters" do
      Dir.mktmpdir do |dir|
        literal = File.join(dir, "ext.rb")
        File.write(literal, "# noop\n")
        configuration = described_class.new("pre_eval" => [literal])
        expect(configuration.pre_eval).to eq([literal])
      end
    end

    it "degrades a match-less glob to an empty entry (no diagnostic, no error)" do
      Dir.mktmpdir do |dir|
        config_path = File.join(dir, ".rigor.yml")
        File.write(config_path, "pre_eval:\n  - lib/none/**/*.rb\n")
        configuration = described_class.load(config_path)
        expect(configuration.pre_eval).to be_empty
      end
    end

    it "de-duplicates when multiple globs match the same file" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "x.rb"), "# noop\n")
        config_path = File.join(dir, ".rigor.yml")
        File.write(config_path, "pre_eval:\n  - lib/*.rb\n  - lib/**/*.rb\n")
        configuration = described_class.load(config_path)
        expect(configuration.pre_eval.size).to eq(1)
      end
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

  describe "#unknown_keys" do
    it "records a top-level key the loader does not own" do
      configuration = described_class.new(described_class::DEFAULTS.merge("excludee" => ["x/**"]))

      expect(configuration.unknown_keys).to eq(["excludee"])
    end

    it "does not record a reserved namespace" do
      configuration = described_class.new(described_class::DEFAULTS.merge("rigor_rs" => { "ruby" => "auto" }))

      expect(configuration.unknown_keys).to be_empty
    end

    it "is empty for a conforming config" do
      expect(described_class.new(described_class::DEFAULTS).unknown_keys).to be_empty
    end

    it "does not record `includes:`, which the include merge consumes before this point" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "base.yml"), "libraries: [csv]\n")
        path = File.join(dir, ".rigor.yml")
        File.write(path, "includes:\n  - base.yml\n")

        expect(described_class.load(path).unknown_keys).to be_empty
      end
    end
  end

  describe "KNOWN_KEYS" do
    it "is the DEFAULTS keys plus `includes:` plus the reserved namespaces" do
      expect(described_class::KNOWN_KEYS.to_set).to eq(
        (described_class::DEFAULTS.keys + %w[includes] + described_class::RESERVED_NAMESPACES).to_set
      )
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

  # ADR-103 WD13 — the effect-labels opt-in. PRESENCE is the switch, not truthiness: an annotation in a
  # project's RBS must never create a project-wide cost cliff, so `effects:` in the config file is the
  # only thing (besides running `rigor effects`) that turns collection on.
  describe "#effects_enabled?" do
    it "is false with no effects: key" do
      expect(described_class.new({}).effects_enabled?).to be(false)
      expect(described_class.new({}).effects).to be_nil
    end

    it "is true for an empty block, and for the bare key YAML parses as nil" do
      expect(described_class.new({ "effects" => {} }).effects_enabled?).to be(true)
      expect(described_class.new({ "effects" => nil }).effects_enabled?).to be(true)
    end

    it "keeps the block's body for the slices that read its sub-keys" do
      configuration = described_class.new({ "effects" => { "check" => false } })

      expect(configuration.effects).to eq({ "check" => false })
      expect(configuration.effects).to be_frozen
    end

    # The ad-hoc opt-in `rigor effects` uses when the project configures nothing.
    describe "#with_effects_enabled" do
      it "returns a frozen sibling with an implicit empty block" do
        enabled = described_class.new({ "paths" => ["app"] }).with_effects_enabled

        expect(enabled.effects_enabled?).to be(true)
        expect(enabled.paths).to eq(["app"])
        expect(enabled).to be_frozen
      end

      it "leaves a configuration that already enables effects untouched" do
        configured = described_class.new({ "effects" => { "views" => true } })

        expect(configured.with_effects_enabled).to equal(configured)
      end
    end
  end

  # ADR-103 WD7 / WD14 (#381) — the snapshot keys and the minimal `tolerated:` policy list. Every one
  # resolves to its default when `effects:` is absent, so a consumer reads one uniform surface and never
  # has to ask whether the block was there.
  describe "the effect-snapshot keys" do
    def snapshot_config(snapshot)
      described_class.new({ "effects" => { "snapshot" => snapshot } })
    end

    it "defaults every key with no effects: block at all" do
      configuration = described_class.new({})

      expect(configuration.effects_snapshot_path).to eq(".rigor-effects.yml")
      expect(configuration.effects_snapshot_reach).to eq([])
      expect(configuration.effects_snapshot_gate).to eq(:symmetric)
      expect(configuration.effects_tolerated).to eq([])
    end

    it "reads the configured path, reach globs and gate" do
      configuration = snapshot_config("path" => "effects.yml", "reach" => ["app/**/*.rb"],
                                      "gate" => "additions")

      expect(configuration.effects_snapshot_path).to eq("effects.yml")
      expect(configuration.effects_snapshot_reach).to eq(["app/**/*.rb"])
      expect(configuration.effects_snapshot_gate).to eq(:additions)
    end

    # Tier 2 (`ArgumentError`, the run stops): an unknown gate would silently pick a semantics.
    it "rejects an unknown gate" do
      expect { snapshot_config("gate" => "ratchet") }
        .to raise_error(ArgumentError, /effects\.snapshot\.gate must be one of/)
    end

    # #387 — presets are named by PLUGINS, and plugins load from the configuration being validated, so at
    # this point none is registered. Only the SHAPE is checked here; `Snapshot.expand_reach` runs the
    # existence check, which is the first moment the registered set is complete.
    it "accepts a well-formed preset name no plugin has registered yet" do
      expect(snapshot_config("reach" => ["controllers"]).effects_snapshot_reach).to eq(["controllers"])
    end

    it "rejects a reach entry that is neither a glob nor a well-formed preset name" do
      expect { snapshot_config("reach" => ["Controller Actions"]) }
        .to raise_error(ArgumentError, /neither a file glob nor a well-formed entry-point preset name/)
    end

    describe "tolerated:" do
      it "validates the label SHAPE and sorts the set" do
        configuration = described_class.new({ "effects" => { "tolerated" => %w[nondet.time io.fs] } })

        expect(configuration.effects_tolerated).to eq(%w[io.fs nondet.time])
      end

      it "rejects a malformed label" do
        expect { described_class.new({ "effects" => { "tolerated" => ["IO::Net"] } }) }
          .to raise_error(ArgumentError, /not a well-formed effect label/)
      end

      # A well-formed label the REGISTRY does not know is deliberately accepted here: that is
      # `effect.unknown-label`'s job (#384), and it fails open rather than stopping a run.
      it "accepts a well-formed label the registry has never heard of" do
        expect(described_class.new({ "effects" => { "tolerated" => ["acme.widget"] } }).effects_tolerated)
          .to eq(["acme.widget"])
      end
    end
  end

  # ADR-103 WD5 / WD6 (#385) — the policy keys. Tier 2 answers SHAPE and only shape: a value the loader
  # cannot pick a reading for stops the run, and a value that is merely unknown to the vocabulary loads
  # fine because it fails open (`effect.unknown-label`).
  describe "the effect-policy keys" do
    def policy_config(effects)
      described_class.new({ "effects" => effects })
    end

    it "defaults every key with no effects: block at all" do
      configuration = described_class.new({})

      expect(configuration.effects_labels).to eq([])
      expect(configuration.effects_attribution).to eq({})
      expect(configuration.effects_envelopes).to eq([])
    end

    describe "labels:" do
      it "validates the label shape and sorts the vocabulary" do
        expect(policy_config("labels" => %w[acme.cache acme.bus]).effects_labels)
          .to eq(%w[acme.bus acme.cache])
      end

      it "rejects a malformed label" do
        expect { policy_config("labels" => ["Acme::Cache"]) }
          .to raise_error(ArgumentError, /effects\.labels is not a well-formed effect label/)
      end
    end

    describe "attribution:" do
      it "reads a method-keyed table of label lists" do
        table = policy_config("attribution" => { "Net::HTTP.get" => ["io.net.http"] }).effects_attribution

        expect(table).to eq({ "Net::HTTP.get" => ["io.net.http"] })
        expect(table).to be_frozen
      end

      # The key is a method key exactly as the symbol tables spell one. A key the scanner would never
      # produce is a table that silently colours nothing, which is the failure tier 2 exists to prevent.
      it "rejects a key that is not a method key" do
        expect { policy_config("attribution" => { "Net::HTTP" => ["io"] }) }
          .to raise_error(ArgumentError, /effects\.attribution key is not a method key/)
      end

      it "rejects a malformed label" do
        expect { policy_config("attribution" => { "Net::HTTP.get" => ["IO"] }) }
          .to raise_error(ArgumentError, /effects\.attribution\["Net::HTTP.get"\] is not a well-formed/)
      end

      it "accepts a well-formed label the registry has never heard of" do
        expect(policy_config("attribution" => { "Acme::Cache.fetch" => ["acme.cache"] }).effects_attribution)
          .to eq({ "Acme::Cache.fetch" => ["acme.cache"] })
      end
    end

    describe "envelopes:" do
      it "reads each entry's selector and bound, keeping list order" do
        entries = policy_config(
          "envelopes" => [
            { "match" => "app/presenters/**/*.rb", "effect" => [] },
            { "namespace" => "Policies::*", "effect" => ["mutate.local"] }
          ]
        ).effects_envelopes

        expect(entries).to eq(
          [
            { "match" => "app/presenters/**/*.rb", "namespace" => nil, "effect" => [] },
            { "match" => nil, "namespace" => "Policies::*", "effect" => ["mutate.local"] }
          ]
        )
      end

      # Exactly one selector: naming both would need a precedence rule inside one entry, and naming
      # neither selects the whole project, which is never what an author meant to write.
      it "rejects an entry naming both selectors" do
        expect { policy_config("envelopes" => [{ "match" => "app/**", "namespace" => "A::*", "effect" => [] }]) }
          .to raise_error(ArgumentError, /effects\.envelopes\[0\] must name exactly one of.*got both/m)
      end

      it "rejects an entry naming neither selector" do
        expect { policy_config("envelopes" => [{ "effect" => [] }]) }
          .to raise_error(ArgumentError, /effects\.envelopes\[0\] must name exactly one of.*got neither/m)
      end

      # `effect: []` is a bound (the empty envelope); a MISSING `effect:` is an entry that bounds
      # nothing, and the two must not be spelled the same way.
      it "rejects an entry with no effect: bound" do
        expect { policy_config("envelopes" => [{ "namespace" => "A::*" }]) }
          .to raise_error(ArgumentError, /effects\.envelopes\[0\] has no `effect:` bound/)
      end

      it "rejects a malformed label, naming the entry index" do
        entries = [{ "namespace" => "A", "effect" => [] }, { "match" => "a/**", "effect" => ["Io"] }]

        expect { policy_config("envelopes" => entries) }
          .to raise_error(ArgumentError, /effects\.envelopes\[1\]\.effect is not a well-formed/)
      end
    end
  end
end
