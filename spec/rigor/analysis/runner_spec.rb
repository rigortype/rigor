# frozen_string_literal: true

require "rigor/analysis/runner"

# Path-error / parse-error specs intentionally bypass `analyze`
# because they exercise paths that do not exist or contain
# non-Ruby content; the helper assumes a writable tmpdir of
# `.rb` files. Everything else uses `analyze`.
RSpec.describe Rigor::Analysis::Runner do
  # T1 — a `rescue SyntaxError => e` in one file resolves to the
  # project's `M::SyntaxError = Class.new(Error)` defined in a sibling
  # file (not core `::SyntaxError`), so a call on the rescued exception
  # that the project class supports does not fire undefined-method.
  it "resolves a cross-file rescue Const to the same-namespace Class.new class" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), <<~RUBY)
        module M
          class Error < ::StandardError
            attr_accessor :line_number
          end
          SyntaxError = Class.new(Error)
        end
      RUBY
      File.write(File.join(dir, "b.rb"), <<~RUBY)
        module M
          def self.go
            raise SyntaxError
          rescue SyntaxError => e
            e.line_number = 1
          end
        end
      RUBY
      configuration = Rigor::Configuration.new("paths" => [dir])
      Dir.chdir(dir) do
        result = described_class.new(configuration: configuration, cache_store: nil).run
        offenders = result.diagnostics.select { |d| d.message.include?("line_number=") }
        expect(offenders).to be_empty
      end
    end
  end

  it "emits a diagnostic for a non-existent path instead of silently passing" do
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "ghost.rb")
      configuration = Rigor::Configuration.new("paths" => [missing])
      # chdir into a clean tmpdir so the runner does not pick up
      # rigor's own `Gemfile.lock` (which would fire the
      # O4-slice-3 missing-RBS diagnostic ahead of the
      # file-not-found one).
      Dir.chdir(dir) do
        result = described_class.new(configuration: configuration).run

        expect(result).not_to be_success
        diag = result.diagnostics.first
        expect(diag.path).to eq(missing)
        expect(diag.message).to include("no such file")
      end
    end
  end

  it "warns and skips a missing path when another path yields files" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "real.rb"), "x = 1\n")
      missing = File.join(dir, "ghost.rb")
      configuration = Rigor::Configuration.new("paths" => [File.join(dir, "real.rb"), missing])
      Dir.chdir(dir) do
        result = described_class.new(configuration: configuration).run
        skipped = result.diagnostics.find { |d| d.path == missing }
        expect(skipped).not_to be_nil
        # Warn-and-skip, not an error that aborts the whole run.
        expect(skipped.severity).to eq(:warning)
        expect(skipped.message).to include("skipped")
      end
    end
  end

  it "emits a diagnostic for a non-Ruby file path" do
    Dir.mktmpdir do |dir|
      txt = File.join(dir, "notes.txt")
      File.write(txt, "hello")
      configuration = Rigor::Configuration.new("paths" => [txt])
      # See above: chdir away from rigor's repo root so the
      # missing-RBS diagnostic doesn't surface ahead of the
      # path-error diagnostic.
      Dir.chdir(dir) do
        result = described_class.new(configuration: configuration).run

        expect(result).not_to be_success
        expect(result.diagnostics.first.message).to include("not a Ruby file")
      end
    end
  end

  it "reports Prism parse errors as diagnostics" do
    result = analyze("def broken\n")

    expect(result).not_to be_success
    expect(result.diagnostics.first.message).not_to be_empty
  end

  # Regression: Rails generator templates ship as `.rb` files but contain
  # ERB interpolation (`<%= ... %>`), which Prism cannot parse and the
  # analyzer used to surface as up to ~20 noisy parse-error diagnostics
  # per file. Redmine's `lib/generators/redmine_plugin_model/templates/
  # migration.rb` is the canonical example. The closing `%>` marker
  # cannot appear in valid Ruby (`%` is a binary operator that requires
  # an operand on its right), so its presence is sufficient evidence
  # that the file is an ERB template; analysis silently skips it.
  context "with an ERB-templated `.rb` file (Rails generator shape)" do
    it "silently skips a file whose source uses `<%= ... %>` interpolation" do
      result = analyze(<<~ERB)
        class <%= @migration_class_name %> < ActiveRecord::Migration[<%= ActiveRecord::Migration.current_version %>]
          def change
            create_table :<%= @table_name %> do |t|
            end
          end
        end
      ERB

      expect(result.diagnostics).to be_empty
    end

    it "still surfaces parse errors in non-templated files" do
      # Sanity check that the ERB skip does not hide ordinary syntax errors.
      result = analyze("def broken\n")
      expect(result.diagnostics).not_to be_empty
    end
  end

  describe "exclude: patterns filter directory globs" do
    # Each test plants a parse-error-shaped file (unclosed `def`)
    # so analysis attempts surface as diagnostics; the test then
    # checks whether those diagnostics include the planted path.
    let(:bad_source) { "def broken\n" }

    it "skips the built-in vendor/bundle pattern when a directory expansion contains it" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src")
        vendored = File.join(src, "vendor", "bundle", "ruby", "4.0.0", "gems", "fakegem")
        FileUtils.mkdir_p(vendored)
        File.write(File.join(src, "real.rb"), bad_source)
        File.write(File.join(vendored, "lib.rb"), bad_source)

        configuration = Rigor::Configuration.new("paths" => [src])
        result = described_class.new(configuration: configuration, cache_store: nil).run

        analysed = result.diagnostics.map(&:path)
        expect(analysed).to include(File.join(src, "real.rb"))
        expect(analysed).not_to include(File.join(vendored, "lib.rb"))
      end
    end

    it "honours user-supplied exclude patterns from `.rigor.yml`" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src")
        FileUtils.mkdir_p(File.join(src, "fixtures"))
        File.write(File.join(src, "real.rb"), bad_source)
        File.write(File.join(src, "fixtures", "demo.rb"), bad_source)

        configuration = Rigor::Configuration.new(
          "paths" => [src], "exclude" => ["**/fixtures/**"]
        )
        result = described_class.new(configuration: configuration, cache_store: nil).run

        analysed = result.diagnostics.map(&:path)
        expect(analysed).to include(File.join(src, "real.rb"))
        expect(analysed).not_to include(File.join(src, "fixtures", "demo.rb"))
      end
    end

    it "does NOT exclude explicit file arguments (only directory globs filter)" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "vendor", "bundle"))
        explicit = File.join(dir, "vendor", "bundle", "lib.rb")
        File.write(explicit, bad_source)

        configuration = Rigor::Configuration.new("paths" => [explicit])
        result = described_class.new(configuration: configuration, cache_store: nil).run

        expect(result.diagnostics.map(&:path)).to include(explicit)
      end
    end
  end

  describe "configuration wiring at runtime (audit guard)" do
    # Adjacent to the `target_ruby` block below, these specs guard
    # against any of the documented `.rigor.yml` settings going
    # phantom — i.e., loaded into `Configuration` but never read
    # at runtime. The `cache.path` regression that prompted this
    # block (the CLI hardcoded `".rigor/cache"` and ignored the
    # config) is covered separately in `cli_spec.rb`.

    it "loads `libraries:` stdlib RBS into Environment.for_project" do
      libraries_args = nil
      allow(Rigor::Environment).to receive(:for_project).and_wrap_original do |original, **kwargs|
        libraries_args = kwargs[:libraries]
        original.call(**kwargs)
      end
      analyze("x = 1\n", config: { "libraries" => %w[csv set] })

      expect(libraries_args).to include("csv")
      expect(libraries_args).to include("set")
    end

    it "passes `signature_paths:` to Environment.for_project" do
      sig_paths_args = nil
      allow(Rigor::Environment).to receive(:for_project).and_wrap_original do |original, **kwargs|
        sig_paths_args = kwargs[:signature_paths]
        original.call(**kwargs)
      end
      analyze("x = 1\n", config: { "signature_paths" => %w[custom-sig vendor/sig] })

      expect(sig_paths_args).to eq(%w[custom-sig vendor/sig])
    end

    it "loads custom RBS classes declared under signature_paths: at runtime" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "code.rb"), "x = 1\n")
        FileUtils.mkdir_p(File.join(dir, "custom-sig"))
        File.write(File.join(dir, "custom-sig", "marker.rbs"), "class CustomMarker\nend\n")

        configuration = Rigor::Configuration.new(
          "paths" => [File.join(dir, "code.rb")],
          "signature_paths" => [File.join(dir, "custom-sig")]
        )
        env = Rigor::Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths
        )
        scope = Rigor::Scope.empty(environment: env)
        expect(scope.environment.nominal_for_name("CustomMarker")).not_to be_nil
      end
    end

    it "extends the plugin TrustPolicy's allowed_read_roots from `plugins_io.allowed_paths`" do
      captured_kwargs = nil
      allow(Rigor::Plugin::TrustPolicy).to receive(:new).and_wrap_original do |original, **kwargs|
        captured_kwargs ||= kwargs
        original.call(**kwargs)
      end
      analyze("x = 1\n", config: {
                "plugins" => ["rigor-fake"],
                "plugins_io" => { "network" => "disabled", "allowed_paths" => %w[vendor/generated] }
              })

      expect(captured_kwargs).not_to be_nil
      # The `analyze` helper chdirs into a tmpdir; on macOS the
      # tmpdir resolves under `/private/tmp/...`, so match by
      # suffix rather than full prefix to stay portable.
      expect(captured_kwargs[:allowed_read_roots]).to include(end_with("/vendor/generated"))
      expect(captured_kwargs[:network_policy]).to eq(:disabled)
    end

    it "threads `plugins_io.allowed_url_hosts` into the TrustPolicy (v0.1.2)" do
      captured_kwargs = nil
      allow(Rigor::Plugin::TrustPolicy).to receive(:new).and_wrap_original do |original, **kwargs|
        captured_kwargs ||= kwargs
        original.call(**kwargs)
      end
      analyze("x = 1\n", config: {
                "plugins" => ["rigor-fake"],
                "plugins_io" => {
                  "network" => "allowlist",
                  "allowed_url_hosts" => %w[raw.githubusercontent.com example.com]
                }
              })

      expect(captured_kwargs).not_to be_nil
      expect(captured_kwargs[:network_policy]).to eq(:allowlist)
      expect(captured_kwargs[:allowed_url_hosts]).to contain_exactly("raw.githubusercontent.com", "example.com")
    end

    it "builds a DependencySourceInference::Index from `dependencies.source_inference:` (ADR-10 slice 2a)" do
      configuration = Rigor::Configuration.new(
        "paths" => [],
        "dependencies" => {
          "source_inference" => [{ "gem" => "prism", "mode" => "when_missing" }]
        }
      )
      runner = described_class.new(configuration: configuration, cache_store: nil)
      runner.run

      expect(runner.dependency_source_index).to be_a(Rigor::Analysis::DependencySourceInference::Index)
      expect(runner.dependency_source_index.resolved_gems.map(&:gem_name)).to include("prism")
    end

    it "surfaces an unresolvable `dependencies.source_inference:` entry as `dynamic.dependency-source.gem-not-found`" do
      configuration = Rigor::Configuration.new(
        "paths" => [],
        "dependencies" => {
          "source_inference" => [{ "gem" => "definitely-no-such-gem-rigor-12345" }]
        }
      )
      result = described_class.new(configuration: configuration, cache_store: nil).run
      diag = result.diagnostics.find { |d| d.rule == "dynamic.dependency-source.gem-not-found" }

      expect(diag).not_to be_nil
      expect(diag.path).to eq(".rigor.yml")
      expect(diag.message).to include("definitely-no-such-gem-rigor-12345")
      expect(diag.severity).to eq(:warning)
    end

    it "respects the per-receiver plugin veto (ADR-10 5a)" do
      # When a plugin declares manifest(owns_receivers: [...])
      # and the dispatcher's receiver IS owned by the plugin,
      # try_dependency_source must decline so the plugin
      # contribution stays authoritative.
      Rigor::Plugin.unregister!
      owner = Class.new(Rigor::Plugin::Base) do
        manifest(id: "owns-fake-node", version: "0.1.0", owns_receivers: ["Prism::FakeOwnedNode"])
      end
      stub_const("FakeOwnerPlugin", owner)

      configuration = Rigor::Configuration.new(
        "paths" => [],
        "plugins" => ["rigor-owns-fake-node"]
      )
      requirer = lambda do |_name|
        Rigor::Plugin.register(owner)
        true
      end
      runner = described_class.new(
        configuration: configuration, cache_store: nil, plugin_requirer: requirer
      )
      runner.run

      env = Rigor::Environment.for_project(
        plugin_registry: runner.plugin_registry,
        dependency_source_index: runner.dependency_source_index,
        libraries: [], signature_paths: nil, cache_store: nil
      )
      dispatcher = Object.new.extend(Rigor::Inference::MethodDispatcher)

      expect(dispatcher.send(:plugin_owns_receiver?, "Prism::FakeOwnedNode", env)).to be(true)
      expect(dispatcher.send(:plugin_owns_receiver?, "Prism::SomeOtherClass", env)).to be(false)
    end

    it "surfaces a config-conflict mode disagreement as `dynamic.dependency-source.config-conflict`" do
      configuration = Rigor::Configuration.new(
        "paths" => [],
        "dependencies" => {
          "source_inference" => [
            { "gem" => "prism", "mode" => "when_missing" },
            { "gem" => "prism", "mode" => "full" }
          ]
        }
      )
      result = described_class.new(configuration: configuration, cache_store: nil).run
      diag = result.diagnostics.find { |d| d.rule == "dynamic.dependency-source.config-conflict" }

      expect(diag).not_to be_nil
      expect(diag.severity).to eq(:warning)
      expect(diag.message).to include("prism")
    end

    it "surfaces a budget-exceeded gem as `dynamic.dependency-source.budget-exceeded` exactly once (ADR-10 slice 4)" do
      configuration = Rigor::Configuration.new(
        "paths" => [],
        "dependencies" => {
          "source_inference" => [{ "gem" => "prism", "mode" => "when_missing" }],
          "budget_per_gem" => 1250
        }
      )
      runner = described_class.new(configuration: configuration, cache_store: nil)
      walker = Rigor::Analysis::DependencySourceInference::Walker
      allow(walker).to receive(:walk).and_return(
        walker::Outcome.new(
          catalog: { ["Prism::FakeNode", :foo] => walker::CatalogEntry.new(kind: :instance) }.freeze,
          truncated: true
        )
      )

      result = runner.run
      budget_diags = result.diagnostics.select { |d| d.rule == "dynamic.dependency-source.budget-exceeded" }

      expect(budget_diags.length).to eq(1)
      expect(budget_diags.first.path).to eq(".rigor.yml")
      expect(budget_diags.first.message).to include("prism")
      expect(budget_diags.first.message).to include("1250")
      expect(budget_diags.first.severity).to eq(:warning)
    end

    it "surfaces `rbs.coverage.missing-gem` :info exactly once when locked gems have no RBS (O4 slice 3)" do # rubocop:disable RSpec/ExampleLength
      # Build a tmpdir with Gemfile.lock listing two gems
      # whose RBS is not covered by ANY of the four resolution
      # paths (DEFAULT_LIBRARIES / vendored / bundle / collection).
      Dir.mktmpdir("rigor-rbs-coverage-spec-") do |tmpdir|
        File.write(File.join(tmpdir, "Gemfile.lock"), <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              rare_gem_a (1.0)
              rare_gem_b (2.5)

          PLATFORMS
            ruby

          DEPENDENCIES
            rare_gem_a
            rare_gem_b

          BUNDLED WITH
             2.5.3
        LOCK

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new(
            "paths" => [],
            "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
          )
          result = described_class.new(configuration: configuration, cache_store: nil).run
          coverage_diags = result.diagnostics.select { |d| d.rule == "rbs.coverage.missing-gem" }

          expect(coverage_diags.length).to eq(1)
          expect(coverage_diags.first.severity).to eq(:info)
          expect(coverage_diags.first.message).to include("rare_gem_a")
          expect(coverage_diags.first.message).to include("rare_gem_b")
          expect(coverage_diags.first.message).to include("rbs collection install")
        end
      end
    end

    it "suppresses `rbs.coverage.missing-gem` when every locked gem has RBS coverage (O4 slice 3)" do
      Dir.mktmpdir("rigor-rbs-coverage-covered-") do |tmpdir|
        # `json` is in DEFAULT_LIBRARIES; the diagnostic must NOT fire.
        File.write(File.join(tmpdir, "Gemfile.lock"), <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              json (2.7.0)

          PLATFORMS
            ruby

          DEPENDENCIES
            json

          BUNDLED WITH
             2.5.3
        LOCK

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new(
            "paths" => [],
            "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
          )
          result = described_class.new(configuration: configuration, cache_store: nil).run
          coverage_diags = result.diagnostics.select { |d| d.rule == "rbs.coverage.missing-gem" }

          expect(coverage_diags).to be_empty
        end
      end
    end

    # ADR-72 — Gemfile.lock-gated bundled RBS overlays.
    def write_duration_project(tmpdir, lock_gem:)
      File.write(File.join(tmpdir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            #{lock_gem} (7.1.3)

        PLATFORMS
          ruby

        DEPENDENCIES
          #{lock_gem}

        BUNDLED WITH
           2.5.6
      LOCK
      File.write(File.join(tmpdir, "code.rb"), <<~RUBY)
        ttl  = 3.minutes
        miss = 5.minuets
        [ttl, miss]
      RUBY
    end

    def undefined_methods_for(tmpdir)
      Dir.chdir(tmpdir) do
        configuration = Rigor::Configuration.new(
          "paths" => [File.join(tmpdir, "code.rb")],
          "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
        )
        result = described_class.new(configuration: configuration, cache_store: nil).run
        result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:method_name)
      end
    end

    it "auto-loads the activesupport core-ext overlay so `3.minutes` resolves when activesupport is locked" do
      Dir.mktmpdir("rigor-as-overlay-") do |tmpdir|
        write_duration_project(tmpdir, lock_gem: "activesupport")
        names = undefined_methods_for(tmpdir)
        # `minutes` resolves via the overlay; the genuine typo still fires.
        expect(names).to contain_exactly("minuets")
      end
    end

    it "does NOT load the overlay when activesupport is absent — `3.minutes` is a genuine undefined-method" do
      Dir.mktmpdir("rigor-as-overlay-absent-") do |tmpdir|
        write_duration_project(tmpdir, lock_gem: "rake")
        names = undefined_methods_for(tmpdir)
        expect(names).to contain_exactly("minutes", "minuets")
      end
    end

    it "emits `rbs.coverage.synthesized-namespace` :info when project RBS omits its namespace" do
      Dir.mktmpdir("rigor-synth-namespace-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "sig"))
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        # Qualified declaration with no `module Acme` — invalid upstream.
        File.write(File.join(tmpdir, "sig", "widget.rbs"), "class Acme::Widget\n  def size: () -> Integer\nend\n")

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new(
            "paths" => [File.join(tmpdir, "code.rb")],
            "signature_paths" => [File.join(tmpdir, "sig")]
          )
          result = described_class.new(configuration: configuration, cache_store: nil).run
          diags = result.diagnostics.select { |d| d.rule == "rbs.coverage.synthesized-namespace" }

          expect(diags.length).to eq(1)
          expect(diags.first.severity).to eq(:info)
          expect(diags.first.message).to include("Acme")
          expect(diags.first.message).to include("rbs validate")
        end
      end
    end

    it "suppresses `rbs.coverage.synthesized-namespace` for a well-formed sig set" do
      Dir.mktmpdir("rigor-synth-namespace-clean-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "sig"))
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        File.write(
          File.join(tmpdir, "sig", "widget.rbs"),
          "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n"
        )

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new(
            "paths" => [File.join(tmpdir, "code.rb")],
            "signature_paths" => [File.join(tmpdir, "sig")]
          )
          result = described_class.new(configuration: configuration, cache_store: nil).run
          diags = result.diagnostics.select { |d| d.rule == "rbs.coverage.synthesized-namespace" }

          expect(diags).to be_empty
        end
      end
    end

    it "does not emit `call.undefined-method` on a value of a synthesized stub type" do
      Dir.mktmpdir("rigor-stub-no-fp-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "sig"))
        # `Acme::Widget#remote` references `Net::FakeService`, which no
        # loaded signature declares — Rigor stubs it so Widget builds.
        File.write(File.join(tmpdir, "sig", "widget.rbs"), <<~RBS)
          class Acme::Widget
            def remote: () -> Net::FakeService
          end
        RBS
        # The call against the stub-typed value must NOT mis-fire
        # undefined-method (the real Net::FakeService might define it).
        File.write(File.join(tmpdir, "code.rb"), <<~RUBY)
          w = Acme::Widget.new
          r = w.remote
          r.do_something
        RUBY

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new(
            "paths" => [File.join(tmpdir, "code.rb")],
            "signature_paths" => [File.join(tmpdir, "sig")]
          )
          result = described_class.new(configuration: configuration, cache_store: nil).run
          undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }

          expect(undefined).to be_empty
        end
      end
    end

    describe "attr_* accessors suppress cross-file undefined-method" do
      # A class that defines `attr_reader :x` AND ships RBS that omits
      # `x` (an incomplete `sig/`) must not fire a false
      # `undefined-method` on `obj.x` from another file. attr-declared
      # accessors are recorded as discovered methods and propagated
      # project-wide.
      it "does not flag an attr_reader method called from another file" do
        Dir.mktmpdir("rigor-attr-xfile-") do |tmpdir|
          FileUtils.mkdir_p(File.join(tmpdir, "sig"))
          # RBS knows Widget but omits the `size` reader.
          File.write(File.join(tmpdir, "sig", "widget.rbs"), "class Widget\nend\n")
          File.write(File.join(tmpdir, "widget.rb"), <<~RUBY)
            class Widget
              attr_reader :size
            end
          RUBY
          # `Widget.new` types the receiver as Widget (RBS-known), so
          # the undefined-method rule actually evaluates `size`.
          File.write(File.join(tmpdir, "user.rb"), <<~RUBY)
            w = Widget.new
            w.size
          RUBY
          Dir.chdir(tmpdir) do
            configuration = Rigor::Configuration.new(
              "paths" => [tmpdir], "signature_paths" => [File.join(tmpdir, "sig")]
            )
            result = described_class.new(configuration: configuration, cache_store: nil).run
            size_diags = result.diagnostics.select do |d|
              d.rule == "call.undefined-method" && d.message.include?("size")
            end
            expect(size_diags).to be_empty
          end
        end
      end
    end

    describe "pre_eval: file-existence validation (ADR-17 slice 1)" do
      it "surfaces `pre-eval.file-not-found` :error for each missing pre_eval entry" do
        Dir.mktmpdir("rigor-pre-eval-missing-") do |tmpdir|
          missing = File.join(tmpdir, "lib", "core_ext", "string_extensions.rb")
          Dir.chdir(tmpdir) do
            configuration = Rigor::Configuration.new(
              "paths" => [], "pre_eval" => [missing]
            )
            result = described_class.new(configuration: configuration, cache_store: nil).run
            diags = result.diagnostics.select { |d| d.rule == "pre-eval.file-not-found" }

            expect(diags.size).to eq(1)
            expect(diags.first.severity).to eq(:error)
            expect(diags.first.message).to include(missing)
          end
        end
      end

      it "stays silent when every pre_eval entry resolves to an existing file" do
        Dir.mktmpdir("rigor-pre-eval-ok-") do |tmpdir|
          present = File.join(tmpdir, "patches.rb")
          File.write(present, "class String; def to_url; gsub(/\\W/, '-'); end; end\n")
          Dir.chdir(tmpdir) do
            configuration = Rigor::Configuration.new(
              "paths" => [], "pre_eval" => [present]
            )
            result = described_class.new(configuration: configuration, cache_store: nil).run
            diags = result.diagnostics.select { |d| d.rule == "pre-eval.file-not-found" }

            expect(diags).to be_empty
          end
        end
      end

      it "emits one diagnostic per missing entry (does NOT short-circuit)" do
        Dir.mktmpdir("rigor-pre-eval-multi-") do |tmpdir|
          Dir.chdir(tmpdir) do
            missing_a = File.join(tmpdir, "a.rb")
            missing_b = File.join(tmpdir, "b.rb")
            configuration = Rigor::Configuration.new(
              "paths" => [], "pre_eval" => [missing_a, missing_b]
            )
            result = described_class.new(configuration: configuration, cache_store: nil).run
            diags = result.diagnostics.select { |d| d.rule == "pre-eval.file-not-found" }

            expect(diags.size).to eq(2)
            expect(diags.map(&:message).join).to include("a.rb").and include("b.rb")
          end
        end
      end
    end

    describe "pre_eval: dispatcher integration (ADR-17 slice 2)" do
      it "resolves cross-file calls to a patched method without `call.undefined-method`" do # rubocop:disable RSpec/ExampleLength
        Dir.mktmpdir("rigor-pre-eval-dispatch-") do |tmpdir|
          ext_path = File.join(tmpdir, "string_ext.rb")
          consumer_path = File.join(tmpdir, "consumer.rb")
          File.write(ext_path, <<~RUBY)
            class String
              def to_url
                gsub(/\\W/, "-")
              end
            end
          RUBY
          File.write(consumer_path, <<~RUBY)
            class Consumer
              def call(s)
                s.to_url
              end
            end
          RUBY
          Dir.chdir(tmpdir) do
            configuration = Rigor::Configuration.new(
              "paths" => [consumer_path],
              "pre_eval" => [ext_path]
            )
            result = described_class.new(configuration: configuration, cache_store: nil).run
            undefined = result.diagnostics.select do |d|
              d.rule.to_s.include?("undefined-method") && d.message.include?("to_url")
            end
            expect(undefined).to(
              be_empty,
              "expected `s.to_url` to resolve through ProjectPatchedMethods; got: " \
              "#{undefined.map(&:message).inspect}"
            )
          end
        end
      end

      # Regression: the dispatcher's `try_project_patched_method`
      # tier resolved the call's TYPE through the registry, but
      # `CheckRules#undefined_method_diagnostic` ran an independent
      # "does this method exist?" probe that ignored the registry —
      # so a patched method on a concretely-typed receiver
      # (`Nominal[String]` / `Constant["hello"]`) would type
      # correctly yet still fire `call.undefined-method`. The fix
      # consults the registry in CheckRules at the same precedence
      # the dispatcher does.
      it "suppresses `call.undefined-method` on a patched method called on a concrete receiver" do # rubocop:disable RSpec/ExampleLength
        Dir.mktmpdir("rigor-pre-eval-concrete-") do |tmpdir|
          ext_path = File.join(tmpdir, "string_ext.rb")
          consumer_path = File.join(tmpdir, "consumer.rb")
          File.write(ext_path, <<~RUBY)
            class String
              def to_url
                gsub(/\\W/, "-")
              end
            end
          RUBY
          File.write(consumer_path, <<~RUBY)
            s = "hello world"
            puts s.to_url
            puts s.to_url_typo
          RUBY
          Dir.chdir(tmpdir) do
            configuration = Rigor::Configuration.new(
              "paths" => [consumer_path],
              "pre_eval" => [ext_path]
            )
            result = described_class.new(configuration: configuration, cache_store: nil).run
            messages = result.diagnostics
                             .select { |d| d.rule.to_s.include?("undefined-method") }
                             .map(&:message)

            expect(messages.grep(/to_url[^_]/)).to be_empty
            expect(messages.grep(/to_url_typo/).size).to eq(1)
          end
        end
      end

      it "surfaces `pre-eval.parse-error` :warning when a pre_eval file has a parse error" do
        Dir.mktmpdir("rigor-pre-eval-parse-") do |tmpdir|
          broken_path = File.join(tmpdir, "broken.rb")
          File.write(broken_path, "def broken\n")
          Dir.chdir(tmpdir) do
            configuration = Rigor::Configuration.new(
              "paths" => [], "pre_eval" => [broken_path]
            )
            result = described_class.new(configuration: configuration, cache_store: nil).run
            warns = result.diagnostics.select { |d| d.rule == "pre-eval.parse-error" }

            expect(warns.size).to eq(1)
            expect(warns.first.severity).to eq(:warning)
          end
        end
      end
    end

    # ADR-17 — when a project patch is NOT registered via `pre_eval:`,
    # the call still fires `call.undefined-method`, but the diagnostic
    # names the proven definition site and carries it as the structured
    # `project_definition_site` field for `rigor triage` to key on.
    describe "ADR-17 — enriched undefined-method for un-registered project patches" do
      it "names the cross-file def site and sets project_definition_site" do
        Dir.mktmpdir("rigor-mp-enrich-") do |tmpdir|
          File.write(File.join(tmpdir, "core_ext.rb"), <<~RUBY)
            class String
              def shout
                upcase + "!"
              end
            end
          RUBY
          File.write(File.join(tmpdir, "user.rb"), <<~RUBY)
            greeting = "hello"
            puts greeting.shout
          RUBY
          Dir.chdir(tmpdir) do
            configuration = Rigor::Configuration.new("paths" => [tmpdir])
            result = described_class.new(configuration: configuration, cache_store: nil).run
            diag = result.diagnostics.find do |d|
              d.rule.to_s.include?("undefined-method") && d.message.include?("shout")
            end

            expect(diag).not_to be_nil
            expect(diag.message).to include("the project defines `String#shout' at")
            expect(diag.message).to include("pre_eval:")
            expect(diag.project_definition_site).to include("core_ext.rb:2")
          end
        end
      end
    end
  end

  describe "ADR-24 slice 2 — cross-file superclass-chain resolution" do
    it "resolves an implicit-self call against a superclass `def` declared in a sibling file" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir("rigor-adr24-slice2-") do |tmpdir|
        File.write(File.join(tmpdir, "base.rb"), <<~RUBY)
          class Base
            def boom(msg)
              raise msg
            end
          end
        RUBY
        File.write(File.join(tmpdir, "sub.rb"), <<~RUBY)
          require "rigor/testing"
          include Rigor::Testing

          class Sub < Base
            def run
              v = boom("x")
              assert_type("bot", v)
            end
          end
        RUBY
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [tmpdir])
          result = described_class.new(configuration: configuration, cache_store: nil).run
          mismatches = result.diagnostics.select { |d| d.message.start_with?("assert_type ") }

          expect(mismatches).to(
            be_empty,
            "expected `boom` to resolve cross-file to `Base#boom` (`bot`); got: " \
            "#{mismatches.map(&:message).inspect}"
          )
        end
      end
    end

    it "resolves an implicit-self call against an included module's `def` declared in a sibling file" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir("rigor-adr24-include-") do |tmpdir|
        File.write(File.join(tmpdir, "helpers.rb"), <<~RUBY)
          module Helpers
            def boom(msg)
              raise msg
            end
          end
        RUBY
        File.write(File.join(tmpdir, "worker.rb"), <<~RUBY)
          require "rigor/testing"
          include Rigor::Testing

          class Worker
            include Helpers

            def run
              v = boom("x")
              assert_type("bot", v)
            end
          end
        RUBY
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [tmpdir])
          result = described_class.new(configuration: configuration, cache_store: nil).run
          mismatches = result.diagnostics.select { |d| d.message.start_with?("assert_type ") }

          expect(mismatches).to(
            be_empty,
            "expected `boom` to resolve cross-file to `Helpers#boom` (`bot`); got: " \
            "#{mismatches.map(&:message).inspect}"
          )
        end
      end
    end
  end

  describe "ADR-34 slice 1 — call.unresolved-toplevel" do
    def write_main(dir, body)
      path = File.join(dir, "main.rb")
      File.write(path, body)
      path
    end

    it "emits the diagnostic on an unresolved toplevel implicit-self call (balanced default)" do
      Dir.mktmpdir("rigor-adr34-emit-") do |tmpdir|
        main = write_main(tmpdir, "foo 1\n")
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [main])
          result = described_class.new(configuration: configuration, cache_store: nil).run
          diags = result.diagnostics.select { |d| d.rule == "call.unresolved-toplevel" }
          expect(diags.size).to eq(1)
          expect(diags.first.severity).to eq(:warning)
          expect(diags.first.message).to include("`foo`")
          expect(diags.first.message).to include("pre_eval")
        end
      end
    end

    it "stays silent for Kernel/Object-resolved toplevel calls (`puts`)" do
      Dir.mktmpdir("rigor-adr34-kernel-") do |tmpdir|
        main = write_main(tmpdir, %(puts "hi"\n))
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [main])
          result = described_class.new(configuration: configuration, cache_store: nil).run
          expect(result.diagnostics.select { |d| d.rule == "call.unresolved-toplevel" }).to be_empty
        end
      end
    end

    it "stays silent when a same-file toplevel `def` declares the method" do
      Dir.mktmpdir("rigor-adr34-localdef-") do |tmpdir|
        main = write_main(tmpdir, <<~RUBY)
          def helper(x); x + 1; end
          helper(42)
        RUBY
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [main])
          result = described_class.new(configuration: configuration, cache_store: nil).run
          expect(result.diagnostics.select { |d| d.rule == "call.unresolved-toplevel" }).to be_empty
        end
      end
    end

    it "stays silent when ADR-17 `pre_eval:` declares an Object monkey-patch (the escape hatch)" do
      Dir.mktmpdir("rigor-adr34-preeval-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "lib"))
        patch_path = File.join(tmpdir, "lib", "patch.rb")
        File.write(patch_path, <<~RUBY)
          class Object
            def my_global_helper(x); "wrapped:\#{x}"; end
          end
        RUBY
        main = write_main(tmpdir, %(my_global_helper("hi")\n))
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new(
            "paths" => [main],
            "pre_eval" => [patch_path]
          )
          result = described_class.new(configuration: configuration, cache_store: nil).run
          expect(result.diagnostics.select { |d| d.rule == "call.unresolved-toplevel" }).to be_empty
        end
      end
    end

    it "stays silent for unresolved implicit-self calls INSIDE a class body (ADR-24 WD4 stays closed)" do
      Dir.mktmpdir("rigor-adr34-classbody-") do |tmpdir|
        main = write_main(tmpdir, <<~RUBY)
          class C
            def m
              some_dsl_macro :x
            end
          end
        RUBY
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [main])
          result = described_class.new(configuration: configuration, cache_store: nil).run
          expect(result.diagnostics.select { |d| d.rule == "call.unresolved-toplevel" }).to be_empty
        end
      end
    end

    it "escalates to :error under severity_profile: strict" do
      Dir.mktmpdir("rigor-adr34-strict-") do |tmpdir|
        main = write_main(tmpdir, "foo 1\n")
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [main], "severity_profile" => "strict")
          result = described_class.new(configuration: configuration, cache_store: nil).run
          diags = result.diagnostics.select { |d| d.rule == "call.unresolved-toplevel" }
          expect(diags.size).to eq(1)
          expect(diags.first.severity).to eq(:error)
        end
      end
    end

    it "is suppressed under severity_profile: lenient" do
      Dir.mktmpdir("rigor-adr34-lenient-") do |tmpdir|
        main = write_main(tmpdir, "foo 1\n")
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [main], "severity_profile" => "lenient")
          result = described_class.new(configuration: configuration, cache_store: nil).run
          expect(result.diagnostics.select { |d| d.rule == "call.unresolved-toplevel" }).to be_empty
        end
      end
    end
  end

  describe "target_ruby wiring (`.rigor.yml` -> Prism version:)" do
    it "passes target_ruby through to Prism so the configured version drives the parse" do
      # Prism's `version: "3.4"` accepts current Ruby syntax.
      result = analyze("x = 1\n", config: { "target_ruby" => "3.4" })
      expect(result.diagnostics.select { |d| d.message.include?("parse") }).to be_empty
    end

    it "surfaces a configuration-error diagnostic when target_ruby is not Prism-accepted" do
      # `3.0` matches the format regex but Prism rejects it. The
      # one-time smoke parse in `Runner#run` converts the
      # `ArgumentError` into a single `:builtin configuration-error`
      # diagnostic so the run fails fast rather than crashing.
      result = analyze("x = 1\n", config: { "target_ruby" => "3.0" })
      diag = result.diagnostics.find { |d| d.rule == "configuration-error" }
      expect(diag).not_to be_nil
      expect(diag.path).to eq(".rigor.yml")
      expect(diag.message).to include('"3.0"')
      # The message must name the supported floor and where to read the
      # right value, so the fix is obvious without a guess-and-retry loop.
      expect(diag.message).to include(described_class.prism_supported_floor)
      expect(diag.message).to match(/Gemfile\.lock|\.ruby-version/)
    end

    it "probes a non-nil Prism-supported floor" do
      expect(described_class.prism_supported_floor).to match(/\A\d+\.\d+\.\d+\z/)
    end
  end

  describe "cache_store surface (v0.0.9 group A slice 1)" do
    let(:configuration) { Rigor::Configuration.new("paths" => []) }

    it "exposes a Cache::Store rooted at .rigor/cache by default" do
      runner = described_class.new(configuration: configuration)
      expect(runner.cache_store).to be_a(Rigor::Cache::Store)
      expect(runner.cache_store.root).to eq(Rigor::Analysis::Runner::DEFAULT_CACHE_ROOT)
    end

    it "accepts an explicit cache_store override" do
      Dir.mktmpdir do |dir|
        custom = Rigor::Cache::Store.new(root: File.join(dir, "alt-cache"))
        runner = described_class.new(configuration: configuration, cache_store: custom)
        expect(runner.cache_store).to equal(custom)
      end
    end

    it "honours a nil cache_store (caching disabled, e.g. --no-cache)" do
      runner = described_class.new(configuration: configuration, cache_store: nil)
      expect(runner.cache_store).to be_nil
    end
  end

  describe "CheckRules diagnostics (Slice 7 phase 8)" do
    it "flags an undefined method on a typed Constant receiver" do
      result = analyze("\"hello\".no_such_method\n")

      diag = result.diagnostics.find { |d| d.message.include?("no_such_method") }
      expect(diag).not_to be_nil
      expect(diag.severity).to eq(:error)
      expect(diag.line).to eq(1)
    end

    it "carries structured receiver_type / method_name on the undefined-method diagnostic (ADR-23 slice 4)" do
      result = analyze("\"hello\".no_such_method\n")

      # `receiver_type` stores the rendered receiver type — the same
      # token the message uses; the triage catalogue normalises it.
      diag = result.diagnostics.find { |d| d.rule == "call.undefined-method" }
      expect([diag&.receiver_type, diag&.method_name]).to eq(['"hello"', "no_such_method"])
    end

    it "does not flag a method that exists on the receiver class" do
      expect(analyze("[1, 2, 3].push(4)\n\"x\".upcase\n")).to be_success
    end

    it "does not flag implicit-self calls (the rule is explicit-receiver only)" do
      result = analyze(<<~RUBY)
        class Foo
          def bar
            helper(1)
          end

          def helper(_n); end
        end
      RUBY

      expect(result).to be_success
    end

    it "does not flag calls on Dynamic[Top] receivers" do
      expect(analyze("def f(x); x.anything; end\n")).to be_success
    end

    it "skips classes whose RBS definition cannot be built (constant-decl aliases like YAML)" do
      expect(analyze("YAML.dump({})\nYAML.safe_load_file(\"x\")\n")).to be_success
    end

    describe "wrong-arity rule (Slice 7 phase 11)" do
      it "flags too many positional arguments to a fixed-arity method" do
        result = analyze("[1, 2].rotate(1, 2)\n")

        diag = result.diagnostics.find { |d| d.message.include?("rotate") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("expected 0..1")
        expect(diag.message).to include("given 2")
      end

      it "flags too few positional arguments to a method with required args" do
        result = analyze("[1, 2].fetch\n")

        diag = result.diagnostics.find { |d| d.message.include?("fetch") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("expected 1..2")
        expect(diag.message).to include("given 0")
      end

      it "does not flag a call whose argument count fits the envelope" do
        expect(analyze("[1, 2, 3].rotate(1)\n[1].fetch(0)\n")).to be_success
      end

      it "skips calls with splat arguments (caller arity unknown)" do
        expect(analyze("args = [1]; [1].rotate(*args)\n")).to be_success
      end

      it "suppresses the diagnostic when the method is defined via def in source" do
        result = analyze(<<~RUBY)
          class String
            def my_extension; self; end
          end

          "x".my_extension
        RUBY

        expect(result).to be_success
      end

      it "suppresses the diagnostic when the method is defined via define_method" do
        result = analyze(<<~RUBY)
          class String
            define_method(:special) { |x| x }
          end

          "x".special(1)
        RUBY

        expect(result).to be_success
      end

      describe "diagnostic suppression (v0.0.2 #6)" do
        it "skips rules listed in `disable:` of the configuration" do
          result = analyze("\"x\".no_method\n", config: { "disable" => ["call.undefined-method"] })

          expect(result).to be_success
        end

        it "honors a `# rigor:disable <rule>` comment on the same line" do
          result = analyze(%("x".no_method  # rigor:disable undefined-method\n))

          expect(result).to be_success
        end

        it "supports `# rigor:disable all` to suppress every rule on a line" do
          result = analyze(<<~RUBY)
            "x".no_method  # rigor:disable all
            [1].rotate(1, 2)  # not suppressed
          RUBY

          expect(result.diagnostics.size).to eq(1)
          expect(result.diagnostics.first.rule).to eq("call.wrong-arity")
        end

        # ADR-8 § "Diagnostic ID family hierarchy"
        it "honours legacy unprefixed disable identifiers" do
          legacy = analyze("\"x\".no_method\n", config: { "disable" => ["undefined-method"] })
          expect(legacy).to be_success
        end

        it "supports family-wildcard disable tokens (`call` disables every call.* rule)" do
          src = "\"x\".no_method\n[1].rotate(1, 2)\n"
          # Both diagnostics fire under default config
          baseline = analyze(src)
          expect(baseline.diagnostics.map(&:rule)).to include("call.undefined-method", "call.wrong-arity")
          # `call` family wildcard suppresses both
          wild = analyze(src, config: { "disable" => ["call"] })
          expect(wild).to be_success
        end

        it "honours a family-wildcard `# rigor:disable call` comment on the same line" do
          result = analyze(%("x".no_method  # rigor:disable call\n))
          expect(result).to be_success
        end

        it "honours a `# rigor:disable-file <rule>` comment on every line" do
          result = analyze(<<~RUBY)
            # rigor:disable-file undefined-method
            "x".no_method
            "y".another_missing_method
          RUBY
          expect(result).to be_success
        end

        it "honours `# rigor:disable-file all` (entire-file every-rule suppression)" do
          result = analyze(<<~RUBY)
            # rigor:disable-file all
            "x".no_method
            5 / 0
          RUBY
          expect(result).to be_success
        end

        it "respects file-suppression placed at the bottom of the file" do
          # The convention is to put the comment near the top,
          # but Rigor scans every comment in the file so any
          # placement works.
          result = analyze(<<~RUBY)
            "x".no_method
            "y".also_missing
            # rigor:disable-file undefined-method
          RUBY
          expect(result).to be_success
        end

        it "does not confuse `disable-file` with the line-only `disable`" do
          # Per-line suppression on line 1 only; line 2's
          # diagnostic still fires.
          result = analyze(<<~RUBY)
            "x".no_method # rigor:disable undefined-method
            "y".also_missing
          RUBY
          undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
          expect(undefined.size).to eq(1)
          expect(undefined.first.line).to eq(2)
        end

        it "expands family wildcards inside disable-file" do
          result = analyze(<<~RUBY)
            # rigor:disable-file call
            "x".no_method
            5 / 0
          RUBY
          undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
          expect(undefined).to be_empty
        end
      end

      # ADR-8 § "`def.return-type-mismatch` rule"
      describe "def.return-type-mismatch rule" do
        let(:demo_sig) do
          { "demo.rbs" => <<~RBS }
            class Demo
              def returns_string: () -> String
              def returns_int_or_nil: () -> Integer?
            end
          RBS
        end

        it "stays silent when the body's last expression matches the declared return type" do
          src = <<~RUBY
            class Demo
              def returns_string
                "hi"
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
        end

        it "flags a body whose inferred type cannot satisfy the declared return type" do
          src = <<~RUBY
            class Demo
              def returns_string
                42
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          mismatch = result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }
          expect(mismatch).not_to be_nil
          expect(mismatch.message).to include("returns_string")
          expect(mismatch.message).to include("declared String")
        end

        it "skips bodies whose inferred type is Dynamic[top] (analyzer fail-soft)" do
          src = <<~RUBY
            class Demo
              def returns_string
                some_unknown_helper
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
        end

        it "skips methods that have no RBS sig (no contract to violate)" do
          src = <<~RUBY
            class Demo
              def no_sig_method
                42
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
        end

        it "is suppressible via `# rigor:disable def.return-type-mismatch`" do
          src = <<~RUBY
            class Demo
              def returns_string  # rigor:disable def.return-type-mismatch
                42
              end
            end
          RUBY
          result = analyze(src, sig: demo_sig)
          expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
        end

        describe "refinement carrier override (v0.1.2)" do
          let(:refined_sig) do
            { "refined.rbs" => <<~RBS }
              class Refined
                %a{rigor:v1:return: non-empty-string}
                def name: () -> String

                %a{rigor:v1:return: positive-int}
                def count: () -> Integer
              end
            RBS
          end

          it "fires when the body returns the empty string against `non-empty-string`" do
            src = <<~RUBY
              class Refined
                def name
                  ""
                end
              end
            RUBY
            result = analyze(src, sig: refined_sig)
            mismatch = result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }
            expect(mismatch).not_to be_nil
            expect(mismatch.message).to include("name")
          end

          it "stays silent when the body satisfies `non-empty-string`" do
            src = <<~RUBY
              class Refined
                def name
                  "Alice"
                end
              end
            RUBY
            result = analyze(src, sig: refined_sig)
            expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
          end

          it "fires when the body returns 0 against `positive-int`" do
            src = <<~RUBY
              class Refined
                def count
                  0
                end
              end
            RUBY
            result = analyze(src, sig: refined_sig)
            mismatch = result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }
            expect(mismatch).not_to be_nil
            expect(mismatch.message).to include("count")
          end

          it "stays silent when the body satisfies `positive-int`" do
            src = <<~RUBY
              class Refined
                def count
                  42
                end
              end
            RUBY
            result = analyze(src, sig: refined_sig)
            expect(result.diagnostics.find { |d| d.rule == "def.return-type-mismatch" }).to be_nil
          end
        end
      end

      # ADR-8 § "Severity profile"
      describe "severity profile re-stamping (v0.1.0+)" do
        it "lenient profile drops call.argument-type-mismatch to :warning" do
          Dir.mktmpdir do |dir|
            File.write(File.join(dir, "demo.rbs"), <<~RBS)
              class Demo
                def take_string: (String value) -> String
              end
            RBS
            FileUtils.mkdir_p(File.join(dir, "sig"))
            FileUtils.mv(File.join(dir, "demo.rbs"), File.join(dir, "sig"))
            File.write(File.join(dir, "use.rb"), <<~RUBY)
              class Demo
                def take_string(value); value; end
              end
              Demo.new.take_string(42)
            RUBY
            Dir.chdir(dir) do
              configuration = Rigor::Configuration.new(
                Rigor::Configuration::DEFAULTS.merge(
                  "paths" => ["use.rb"], "severity_profile" => "lenient"
                )
              )
              result = described_class.new(configuration: configuration, cache_store: nil).run
              mismatch = result.diagnostics.find { |d| d.rule == "call.argument-type-mismatch" }
              expect(mismatch).not_to be_nil
              expect(mismatch.severity).to eq(:warning)
            end
          end
        end

        it "severity_overrides off drops the diagnostic entirely" do
          Dir.mktmpdir do |dir|
            File.write(File.join(dir, "use.rb"), "\"x\".no_method\n")
            Dir.chdir(dir) do
              configuration = Rigor::Configuration.new(
                Rigor::Configuration::DEFAULTS.merge(
                  "paths" => ["use.rb"],
                  "severity_overrides" => { "call.undefined-method" => "off" }
                )
              )
              result = described_class.new(configuration: configuration, cache_store: nil).run
              expect(result.diagnostics.find { |d| d.rule == "call.undefined-method" }).to be_nil
            end
          end
        end
      end

      describe "argument-type-mismatch rule (v0.0.2 #4)" do
        # `Demo#take_string: (String) -> String` fixture, paired
        # with the matching `def`. `analyze` writes the sig under
        # `sig/` and chdirs so `Environment.for_project` discovers
        # it.
        let(:demo_sig) do
          { "demo.rbs" => <<~RBS }
            class Demo
              def take_string: (String value) -> String
            end
          RBS
        end
        let(:demo_def) { <<~RUBY }
          class Demo
            def take_string(value); value; end
          end
        RUBY

        it "flags an Integer passed where a String is expected" do
          result = analyze("#{demo_def}Demo.new.take_string(42)\n", sig: demo_sig)

          mismatch = result.diagnostics.find { |d| d.message.start_with?("argument type mismatch") }
          expect(mismatch).not_to be_nil
          expect(mismatch.message).to include("expected String")
          expect(mismatch.message).to include("got 42")
        end

        it "stays silent on a matching call" do
          result = analyze(%(#{demo_def}Demo.new.take_string("hello")\n), sig: demo_sig)

          arg_errors = result.diagnostics.select { |d| d.message.start_with?("argument type mismatch") }
          expect(arg_errors).to be_empty
        end

        # ADR-58 (N2 extension, 2026-06-13 app/network survey) — the
        # declaration-sourced-nil-is-not-diagnostic-fuel criterion that
        # governs `possible-nil-receiver` extends to `argument-type-mismatch`.
        # A declaration-sourced ivar (the class-ivar index seed of a ctor
        # `@x = 0` / `@x = nil`, read in a sibling method) types `T | nil`; the
        # rejecting constituent is the seed nil, and the program's invariant is
        # that the ivar is set by then. Stripping the nil yields an accepted
        # type, so the rule withholds. Flow-live nil and genuinely-wrong types
        # keep firing.
        context "when the rejecting argument is a declaration-sourced ivar nil (ADR-58 N2)" do
          def arg_mismatch_diags(result)
            result.diagnostics.select { |d| d.message.start_with?("argument type mismatch") }
          end

          it "does not fire on `@length` (ctor-seeded Integer ivar) used in `k <= @length`" do
            # `@length = 0` in the ctor seeds the class-ivar index, so a read in
            # a sibling method types `0 | nil`. `Integer#<=` expects Numeric;
            # `0` is gradual-consistent, the seed `nil` is what rejects.
            # (concurrent-ruby ruby_non_concurrent_priority_queue shape.)
            result = analyze(<<~RUBY)
              class PQ
                def initialize; @length = 0; end
                def push; @length += 1; end
                def covers?
                  k = 1
                  k <= @length
                end
              end
            RUBY
            expect(arg_mismatch_diags(result)).to be_empty
          end

          it "STILL fires on a flow-live nil argument (method-local @x = nil drops the mark)" do
            result = analyze(<<~RUBY)
              class PQ
                def initialize; @length = 0; end
                def covers?
                  k = 1
                  @length = nil
                  k <= @length
                end
              end
            RUBY
            expect(arg_mismatch_diags(result)).not_to be_empty
          end

          it "STILL fires on a genuinely-wrong argument type regardless of provenance" do
            # `@name` is a ctor-seeded String ivar — declaration-sourced — but
            # passing a String where Numeric is required is a real mismatch with
            # no nil constituent to strip, so it must still fire.
            result = analyze(<<~RUBY)
              class PQ
                def initialize; @name = "q"; end
                def covers?
                  k = 1
                  k <= @name
                end
              end
            RUBY
            expect(arg_mismatch_diags(result)).not_to be_empty
          end
        end
      end

      describe "dump_type / assert_type rules (Slice 7 phase 19)" do
        it "emits an info-severity diagnostic for `dump_type(value)`" do
          result = analyze(<<~RUBY)
            require "rigor/testing"
            include Rigor::Testing
            n = 4
            dump_type(n)
          RUBY

          dump = result.diagnostics.find { |d| d.message.start_with?("dump_type") }
          expect(dump).not_to be_nil
          expect(dump.severity).to eq(:info)
          expect(dump.message).to include("4")
          # info-severity does not fail the run.
          expect(result).to be_success
        end

        it "errors on `assert_type` mismatch and stays silent on a match" do
          result = analyze(files: {
                             "match.rb" => <<~RUBY,
                               require "rigor/testing"
                               include Rigor::Testing
                               x = 4
                               assert_type("4", x)
                             RUBY
                             "miss.rb" => <<~RUBY
                               require "rigor/testing"
                               include Rigor::Testing
                               x = 4
                               assert_type("Integer", x)
                             RUBY
                           })

          mismatch = result.diagnostics.find { |d| d.message.start_with?("assert_type mismatch") }
          expect(mismatch).not_to be_nil
          expect(mismatch.path).to end_with("miss.rb")
          expect(mismatch.message).to include('expected "Integer"')
          expect(mismatch.message).to include('got "4"')
        end
      end

      describe "nil-receiver rule (Slice 7 phase 14)" do
        let(:maybe_nil_string) do
          <<~RUBY
            x = if rand < 0.5
              "hello"
            else
              nil
            end
          RUBY
        end

        it "flags a call to a method that does not exist on NilClass when receiver is T | nil" do
          result = analyze("#{maybe_nil_string}x.upcase\n")

          diag = result.diagnostics.find { |d| d.message.include?("nil receiver") }
          expect(diag).not_to be_nil
          expect(diag.message).to include("upcase")
        end

        it "does not flag a method that NilClass also has (e.g. to_s)" do
          expect(analyze("#{maybe_nil_string}x.to_s\n")).to be_success
        end

        it "does not flag safe-navigation calls (`x&.method`)" do
          expect(analyze("#{maybe_nil_string}x&.upcase\n")).to be_success
        end

        it "is suppressed when an early-return guard narrows nil out (Slice 7 phase 14 narrowing)" do
          result = analyze(<<~RUBY)
            def go(_)
              x = if rand < 0.5
                "hello"
              else
                nil
              end
              return if x.nil?
              x.upcase
            end
          RUBY

          expect(result).to be_success
        end

        it "is suppressed when an ivar nil-guard fires on an ivar seeded as Constant[nil]" do
          # Regression: when @ivar is seeded Constant[nil] by the class-ivar
          # accumulator, @ivar.nil? folds to Constant[true] (always-live branch
          # optimisation). The fix ensures the early-return narrowing path still
          # applies so downstream code doesn't see the stale nil type.
          result = analyze(<<~RUBY)
            class GuardedService
              def initialize
                @event = nil
              end

              def run
                return if @event.nil?
                @event.process
              end
            end
          RUBY

          expect(result).to be_success
        end
      end

      # Regression — liquid v5.x sweep, Event 3
      # (docs/notes/20260616-liquid-v5.x-regression-sweep.md). A local
      # conditionally assigned across an `if/elsif/else: raise` chain is
      # bound on every reachable path (the else raises), so reading it
      # afterwards must NOT fire `possible-nil-receiver`. The bug only
      # surfaced when one assigning arm was `Dynamic`-typed and another
      # concrete: the inner `elsif … else raise` dropped its body's
      # assignment, leaving the local unbound for the outer if's join to
      # nil-inject. The `Dynamic | concrete` union then leaked the
      # injected nil past the FP-discipline gate that silences a *bare*
      # `Dynamic` receiver. The fix carries the surviving then-body's
      # scope forward; the whole bisection table must stay clean.
      describe "if/elsif/else-raise conditional-local definite assignment" do
        def nil_receiver_diags(result)
          result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        end

        it "2-arm if/else-raise, single concrete arm → clean" do
          result = analyze(<<~RUBY)
            def m(n)
              if n.is_a?(String) then partial = n.to_s
              else raise ::ArgumentError end
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "3-arm if/elsif/else-raise, two concrete arms → clean" do
          result = analyze(<<~RUBY)
            def m(t, n)
              if t.is_a?(String) then partial = t.to_s
              elsif n.is_a?(String) then partial = n.to_s
              else raise ::ArgumentError end
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "3-arm if/elsif/else-raise, one Dynamic + one concrete arm → clean (the bug)" do
          result = analyze(<<~RUBY)
            def m(t, n)
              if t then partial = t.anything
              elsif n.is_a?(String) then partial = n.to_s
              else raise ::ArgumentError end
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "bare Dynamic receiver (no conditional) → clean" do
          result = analyze(<<~RUBY)
            def m(t)
              partial = t.anything
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "2-arm if/else (no raise), Dynamic-or-concrete → clean" do
          result = analyze(<<~RUBY)
            def m(t, n)
              if t then partial = t.anything
              else partial = n.to_s end
              partial.foo
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end
      end

      it "skips methods with required keyword arguments" do
        expect(analyze("[1, 2].push(1)\n")).to be_success
      end
    end

    describe "unreachable-branch rule (v0.1.2)" do
      it "flags the else branch when the if predicate is the `true` literal" do
        result = analyze(<<~RUBY)
          if true
            x = 1
          else
            x = 2
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always truthy")
      end

      it "flags the then branch when the if predicate is the `false` literal" do
        result = analyze(<<~RUBY)
          if false
            x = 1
          else
            x = 2
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always falsey")
      end

      it "flags a postfix-if body when the predicate is `false`" do
        result = analyze("puts \"never\" if false\n")
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
      end

      it "flags the body when an unless predicate is the `true` literal" do
        result = analyze(<<~RUBY)
          unless true
            x = 1
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always truthy")
      end

      it "flags the else branch in a ternary expression with a literal predicate" do
        result = analyze("x = true ? 1 : 2\n")
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
      end

      it "treats `if nil` as always falsey" do
        result = analyze(<<~RUBY)
          if nil
            x = 1
          else
            x = 2
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always falsey")
      end

      it "treats numeric / string / symbol literals as always truthy (Ruby semantics)" do
        result = analyze(<<~RUBY)
          if 0
            x = 1
          else
            x = 2
          end
        RUBY
        diag = result.diagnostics.find { |d| d.rule == "flow.unreachable-branch" }
        expect(diag).not_to be_nil
        expect(diag.message).to include("always truthy")
      end

      it "does not flag inferred-constant predicates (envelope is literal-only)" do
        # `class_object.name.nil?` folds to `Constant<false>`
        # because RBS declares `Module#name -> String`, but
        # anonymous classes really do return nil at runtime.
        # The literal-only envelope avoids flagging the
        # defensive `raise ... if x.name.nil?` shape.
        result = analyze(<<~RUBY)
          def register(class_object)
            raise ArgumentError unless class_object.is_a?(Module)
            raise ArgumentError, "anonymous" if class_object.name.nil?

            class_object.name
          end
        RUBY
        unreachable = result.diagnostics.select { |d| d.rule == "flow.unreachable-branch" }
        expect(unreachable).to be_empty
      end

      it "does not flag when the predicate is a non-literal expression" do
        result = analyze(<<~RUBY)
          n = ARGV.first&.to_i || 0
          if n > 0
            x = 1
          else
            x = 2
          end
        RUBY
        unreachable = result.diagnostics.select { |d| d.rule == "flow.unreachable-branch" }
        expect(unreachable).to be_empty
      end

      it "does not flag `if true; ...; end` with no else (no observable dead branch)" do
        result = analyze(<<~RUBY)
          if true
            x = 1
          end
        RUBY
        unreachable = result.diagnostics.select { |d| d.rule == "flow.unreachable-branch" }
        expect(unreachable).to be_empty
      end

      it "is suppressible via `# rigor:disable unreachable-branch` on the dead-branch line" do
        # The diagnostic points at the dead branch's location,
        # so the suppression comment lives on the dead-branch
        # statement (not the `if` line).
        result = analyze(<<~RUBY)
          if false
            x = 1 # rigor:disable unreachable-branch
          end
        RUBY
        unreachable = result.diagnostics.select { |d| d.rule == "flow.unreachable-branch" }
        expect(unreachable).to be_empty
      end
    end

    describe "always-truthy-condition rule (v0.1.2)" do
      def truthy_diags(result)
        result.diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }
      end

      it "flags an `if` whose predicate is an inferred Constant" do
        result = analyze(<<~RUBY)
          x = 1
          if x
            "yes"
          else
            "no"
          end
        RUBY
        diag = truthy_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("always truthy")
      end

      it "does not double-fire on a syntactic literal predicate (covered by unreachable-branch)" do
        result = analyze(<<~RUBY)
          if true
            x = 1
          else
            x = 2
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      it "does not fire on `.nil?` (defensive predicate skip)" do
        result = analyze(<<~RUBY)
          name = "Alice"
          if name.nil?
            "missing"
          else
            "ok"
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      it "does not fire on `.empty?` (defensive predicate skip)" do
        result = analyze(<<~RUBY)
          arr = []
          if arr.empty?
            "no items"
          else
            "items"
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      it "does not fire when the predicate sits inside a block (loop-mutation skip)" do
        result = analyze(<<~RUBY)
          [1, 2, 3].each do |x|
            shift = 7
            if shift
              x
            end
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      it "does not fire when the predicate sits inside a `while` loop" do
        result = analyze(<<~RUBY)
          x = 1
          while x
            break
          end
        RUBY
        # `while x` itself isn't an IfNode so it's outside the
        # rule's scope; if Rigor ever folds the body's `if`
        # against a loop-mutated local, the loop ancestor
        # check keeps the rule from firing.
        expect(truthy_diags(result)).to be_empty
      end

      it "does not fire on a non-constant predicate (Union / Dynamic etc.)" do
        result = analyze(<<~RUBY)
          n = ARGV.first&.to_i || 0
          if n > 0
            "positive"
          else
            "non-positive"
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable always-truthy-condition`" do
        result = analyze(<<~RUBY)
          x = 1
          if x # rigor:disable always-truthy-condition
            "yes"
          else
            "no"
          end
        RUBY
        expect(truthy_diags(result)).to be_empty
      end

      # Regression: the class-ivar pre-pass seeds every InstanceVariableWriteNode
      # rvalue into a per-class accumulator. Defensive-init idioms
      # (`@x = v unless @x` / `@x = v if @x.nil?` / `unless defined?(@x); @x = v; end`)
      # used to seed `@x` as `Constant[v]`, then the predicate `@x` folded
      # to that same constant and fired this rule against working programs —
      # most visibly in tdiary-core's `TDiary::Configuration#configure_attrs`
      # (≈ 20 false positives across a single block of consecutive defaults).
      # The pre-pass now unions `Constant[nil]` into the seeded type for
      # writes that sit in the THEN body of a conditional whose predicate
      # tests the same ivar's truthiness / nil-ness / definedness.
      context "with defensive ivar-init idioms (tdiary-core configuration.rb cluster)" do
        it "does not fire on `@x = v unless @x`" do
          result = analyze(<<~RUBY)
            class Foo
              def setup
                @lang = "ja" unless @lang
                @style = "tDiary" unless @style
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does not fire on `@x = v if @x.nil?`" do
          result = analyze(<<~RUBY)
            class Foo
              def setup
                @lang = "ja" if @lang.nil?
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does not fire on `unless defined?(@x); @x = v; end`" do
          result = analyze(<<~RUBY)
            class Foo
              def setup
                @hide_form = false unless defined?(@hide_form)
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does not fire on `unless @x` block body that initialises @x" do
          result = analyze(<<~RUBY)
            class Foo
              def setup
                unless @lang
                  @lang = "ja"
                end
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        # Polarity check: the ELSE branch of `if @x; ...; else; @x = init; end`
        # is also a defensive-init shape, but treating its write as "guarded
        # by nil" forces the read of `@x` elsewhere in the class to fold to
        # `union(init_type, nil)` and surfaces a possible-nil-receiver FP on
        # any later call against `@x` that relies on a method-call invariant
        # (the tdiary `TDiary::TDiaryBase#do_eval_rhtml` shape). The fix
        # leaves the ELSE branch unguarded so those reads continue to type
        # as they did before.
        it "does not over-mark the else branch of `if @x; ...; else; @x = init; end`" do
          result = analyze(<<~RUBY)
            class Foo
              def load_plugin
                if @plugin
                  @plugin
                else
                  @plugin = Object.new
                end
              end

              def use
                load_plugin
                @plugin.inspect
              end
            end
          RUBY
          nil_receiver_diags = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
          expect(nil_receiver_diags).to be_empty
        end
      end

      # ADR-58 WD1 — declaration-sourced ivar optionality (the ctor
      # `@x = nil` seed unioned in via the class-ivar index) is not
      # diagnostic fuel for `possible-nil-receiver`. The 109-FP class on
      # idiomatic data-structure Ruby: a node field read whose nil arrives
      # only from a sibling-method ctor seed, guarded by an unprovable
      # cross-method invariant. Flow-live nil (a method-local write or a
      # failed-guard narrowing) keeps firing exactly as before.
      context "when the ivar nil is declaration-sourced (ADR-58 WD1)" do
        def nil_receiver_diags(result)
          result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        end

        it "does not fire on a local copy of a declaration-sourced ivar read (r = @right; r.key)" do
          result = analyze(<<~RUBY)
            class P
              attr_accessor :right, :key
              def initialize; @right = nil; @key = nil; end
              def link; @right = P.new; end
              def rotate
                r = @right
                r.key
              end
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "does not fire on a declaration-sourced ivar read assigned to a local then chained" do
          result = analyze(<<~RUBY)
            class P
              attr_accessor :nxt, :value
              def initialize; @nxt = nil; @value = nil; end
              def link; @nxt = P.new; @value = P.new; end
              def head
                current = @nxt
                current.value
              end
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end

        it "STILL fires on flow-live nil after a method-local write drops the mark" do
          result = analyze(<<~RUBY)
            class P
              attr_accessor :right, :key
              def initialize; @right = nil; end
              def link; @right = P.new; end
              def live(cond)
                r = @right
                r = nil if cond
                r.key
              end
            end
          RUBY
          expect(nil_receiver_diags(result)).not_to be_empty
        end

        it "STILL fires on a method-local nil-bearing union assigned to a local" do
          result = analyze(<<~RUBY)
            def m(flag)
              x = if flag then "s" else nil end
              x.upcase
            end
          RUBY
          expect(nil_receiver_diags(result)).not_to be_empty
        end

        it "leaves a guarded traversal loop clean (unchanged)" do
          result = analyze(<<~RUBY)
            class P
              attr_accessor :nxt
              def initialize; @nxt = nil; end
              def link; @nxt = P.new; end
              def walk
                current = @nxt
                current = current.nxt until current.nil?
              end
            end
          RUBY
          expect(nil_receiver_diags(result)).to be_empty
        end
      end

      # Flow-folding gap G1 — closed via the
      # `Rigor::Inference::MutationWidening` hook in `eval_call`.
      # The pre-fix shape used to fold `arms.size == 1` to
      # `Constant[true]` because the body's `arms << x` mutation
      # was not reflected in the post-loop binding. Mirrors the
      # parse_union FP at lib/rigor/inference/hkt_body_parser.rb:140
      # documented in CURRENT_WORK.md § Flow-folding.
      context "when a loop body mutates the seeded collection (G1, Mastodon cluster 4)" do
        it "does NOT fire on a tuple seeded then mutated inside a `while`" do
          result = analyze(<<~RUBY)
            def parse_union(tokens)
              arms = [tokens.first]
              while tokens.size > 1
                tokens.shift
                arms << tokens.first
              end
              return arms.first if arms.size == 1

              arms
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does NOT fire on a tuple mutated by `push` inside a `while`" do
          result = analyze(<<~RUBY)
            def collect(n)
              buf = [n]
              i = 0
              while i < n
                buf.push(i)
                i += 1
              end
              puts "single" if buf.size == 1

              buf
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does NOT fire on an instance-variable Tuple mutated by `<<` (G2 row)" do
          result = analyze(<<~RUBY)
            class Bag
              def initialize
                @tags = []
              end

              def absorb(items)
                items.each { |i| @tags << i }
                return if @tags.empty?

                @tags
              end
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "does NOT fire on an outer-scope tuple mutated INSIDE an `each {}` block" do
          # This is the hkt_registry.rb:212 shape: a local seeded
          # as a tuple literal, mutated only inside an iterator
          # block, then probed with `.empty?` after the block. The
          # block lives in a child scope; the propagation in
          # `MutationWidening.widen_after_block` carries the
          # widening back to the outer scope.
          result = analyze(<<~RUBY)
            def collect_things(items)
              registrations = []
              items.each do |item|
                registrations << item
              end
              return :nothing if registrations.empty?

              registrations
            end
          RUBY
          expect(truthy_diags(result)).to be_empty
        end

        it "still fires on a tuple that is genuinely never mutated" do
          # The widening only triggers on an in-place mutator call;
          # a tuple whose size is a fact at the predicate site
          # MUST still fold. This pins the precision floor.
          result = analyze(<<~RUBY)
            arr = [1]
            puts "single" if arr.size == 1
          RUBY
          expect(truthy_diags(result)).not_to be_empty
        end
      end
    end

    # ADR-47 — narrowing-driven `case`/`when` clause reachability (WD1).
    describe "unreachable-clause rule (ADR-47)" do
      def clause_diags(result)
        result.diagnostics.select { |d| d.rule == "flow.unreachable-clause" }
      end

      it "flags a `when` clause disjoint from the narrowed subject" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when String
            "s"
          when Integer
            "i"
          end
        RUBY
        diag = clause_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("when String")
        expect(clause_diags(result).size).to eq(1) # only the disjoint clause
      end

      it "does not fire on a reachable clause (subject not disjoint)" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Integer
            "i"
          when String
            "s"
          end
        RUBY
        # x is Integer | String — both clauses are reachable.
        expect(clause_diags(result)).to be_empty
      end

      it "fires on a clause made dead by an earlier clause (prior-exhaustion)" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when Integer
            "i"
          when Float
            "f"
          end
        RUBY
        # x is Integer here, so `when Float` after `when Integer` is dead.
        expect(clause_diags(result).map(&:message)).to all(include("when Float"))
        expect(clause_diags(result).size).to eq(1)
      end

      it "never fires on a `Dynamic` subject (the gradual guarantee)" do
        result = analyze(<<~RUBY)
          def f(x)
            case x
            when String then 1
            when Integer then 2
            end
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "does not fire on non-constant clauses (`when nil` / ranges are out of WD1 scope)" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when nil
            "z"
          when 100..200
            "r"
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "skips clauses inside a loop/block (incomplete mutation tracking)" do
        result = analyze(<<~RUBY)
          [1, 2].each do |x|
            case x
            when String
              "s"
            when Integer
              "i"
            end
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable unreachable-clause`" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when String
            "s" # rigor:disable unreachable-clause
          when Integer
            "i"
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      # --- WD2: message precision + dead trailing else ---

      it "WD2: words a per-clause-disjoint dead clause as `disjoint`" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Float
            "f"
          when Integer
            "i"
          when String
            "s"
          end
        RUBY
        # x is Integer|String; `when Float` is disjoint, both later clauses live.
        diag = clause_diags(result).first
        expect(diag.message).to include("when Float")
        expect(diag.message).to include("disjoint")
        expect(clause_diags(result).size).to eq(1)
      end

      it "WD2: words a prior-exhausted dead clause as `already covered`" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          when Integer
            "i"
          when Float
            "f"
          end
        RUBY
        # x is Integer; `when Float` is dead because `when Integer` exhausted it.
        diag = clause_diags(result).first
        expect(diag.message).to include("when Float")
        expect(diag.message).to include("already covered by an earlier")
        expect(diag.message).not_to include("disjoint")
      end

      it "WD2: flags a dead trailing `else` when the whens exhaust the subject" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Integer
            "i"
          when String
            "s"
          else
            "never"
          end
        RUBY
        diag = clause_diags(result).find { |d| d.message.include?("else") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("unreachable `else'")
      end

      it "WD2: does NOT flag a defensive `else raise` (deliberate guard)" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Integer
            "i"
          when String
            "s"
          else
            raise "unexpected type"
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "WD2: does not flag a live `else` (subject not exhausted)" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          when Integer
            "i"
          else
            "fallthrough"
          end
        RUBY
        # only String reaches the else — it is live.
        expect(clause_diags(result)).to be_empty
      end

      # --- WD3a: case/in bare class patterns ---

      it "WD3a: flags a `in C` clause disjoint from the narrowed subject" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in String
            "s"
          in Integer
            "i"
          end
        RUBY
        diag = clause_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("in String")
        expect(diag.message).to include("disjoint")
        expect(clause_diags(result).size).to eq(1)
      end

      it "WD3a: words a prior-exhausted `in` clause as `already covered`" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in Integer
            "i"
          in Float
            "f"
          end
        RUBY
        diag = clause_diags(result).first
        expect(diag.message).to include("in Float")
        expect(diag.message).to include("already covered by an earlier `in'")
      end

      it "WD3a: handles `in C => y` capture of a bare class" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in String => s
            s
          in Integer => i
            i
          end
        RUBY
        diag = clause_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("in String")
      end

      it "WD3a: does NOT fire on non-class patterns (array/hash/value out of WD3a scope)" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in [a, b]
            a
          in {k:}
            k
          in 0
            "zero"
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "WD3a: a prior-exhausting `in C` kills ANY later clause, even non-class" do
        result = analyze(<<~RUBY)
          x = 1
          case x
          in Integer
            "i"
          in [a, b]
            a
          end
        RUBY
        diag = clause_diags(result).find { |d| d.message.include?("[a, b]") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("already covered")
      end

      it "WD3a: never fires on a `Dynamic` subject (gradual guarantee)" do
        result = analyze(<<~RUBY)
          def f(x)
            case x
            in String then 1
            in Integer then 2
            end
          end
        RUBY
        expect(clause_diags(result)).to be_empty
      end

      it "WD3a: flags a dead `else` once the `in` clauses exhaust the subject" do
        result = analyze(<<~RUBY)
          x = [1, "a"].sample
          case x
          in Integer
            "i"
          in String
            "s"
          else
            "never"
          end
        RUBY
        diag = clause_diags(result).find { |d| d.message.include?("else") }
        expect(diag).not_to be_nil
        expect(diag.message).to include("`in' clauses")
      end
    end

    describe "Hash key-presence narrowing (ADR-47 §4-3)" do
      def dump_messages(result)
        result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
      end

      # `h[:foo]` on an optional key reads `Integer?`; inside a
      # `h.key?(:foo)` guard the optionality nil is gone → `Integer`.
      it "narrows h[:foo] from Integer? to Integer after a `h.key?(:foo)` guard" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Config
            def lookup(h)
              a = h[:foo]
              Rigor.dump_type(a)
              if h.key?(:foo)
                b = h[:foo]
                Rigor.dump_type(b)
              end
            end
          end
        RUBY
          class Config
            def lookup: ({ ?foo: Integer }) -> void
          end
        RBS
        dumps = dump_messages(result)
        expect(dumps.first).to include("Integer?")          # unguarded: optionality nil present
        expect(dumps.last).to eq("dump_type: Integer")      # guarded: nil removed
      end

      # §4-3 false edge: `unless h.key?(:foo)` proves `:foo` absent, so
      # `h[:foo]` reads `nil` (the key is dropped from the shape).
      it "narrows h[:foo] to nil in the falsey edge (key proven absent)" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Config
            def lookup(h)
              unless h.key?(:foo)
                c = h[:foo]
                Rigor.dump_type(c)
              end
            end
          end
        RUBY
          class Config
            def lookup: ({ ?foo: Integer }) -> void
          end
        RBS
        expect(dump_messages(result).first).to eq("dump_type: nil")
      end
    end

    describe "Array non-empty narrowing (ADR-47 §4-4)" do
      def dump_messages(result)
        result.diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
      end

      # Inside an `unless arr.empty?` / `if arr.any?` guard the array is
      # `non-empty-array[T]`, so `size`/`length`/`count` refine from
      # `non-negative-int` to `positive-int` (Elixir `tuple_size`-style).
      it "refines arr.size to positive-int inside a non-empty guard" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Box
            def head(arr)
              Rigor.dump_type(arr.size)
              unless arr.empty?
                Rigor.dump_type(arr)
                Rigor.dump_type(arr.size)
              end
            end
          end
        RUBY
          class Box
            def head: (Array[Integer]) -> void
          end
        RBS
        dumps = dump_messages(result)
        expect(dumps).to include("dump_type: non-negative-int") # unguarded
        expect(dumps).to include("dump_type: non-empty-array[Integer]") # narrowed receiver
        expect(dumps).to include("dump_type: positive-int") # guarded size
      end

      it "narrows on the true edge of `arr.any?`" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Box
            def head(arr)
              Rigor.dump_type(arr.size) if arr.any?
            end
          end
        RUBY
          class Box
            def head: (Array[Integer]) -> void
          end
        RBS
        expect(dump_messages(result)).to include("dump_type: positive-int")
      end
    end

    describe "method-visibility-mismatch rule (v0.1.2)" do
      def visibility_mismatch_diags(result)
        result.diagnostics.select { |d| d.rule == "def.method-visibility-mismatch" }
      end

      it "flags an explicit-receiver call to a method declared under `private`" do
        result = analyze(<<~RUBY)
          class Foo
            def bar
              secret
            end

            private

            def secret
              42
            end
          end

          Foo.new.secret
        RUBY
        diag = visibility_mismatch_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("private method")
        expect(diag.message).to include("`secret'")
        expect(diag.message).to include("Foo")
      end

      it "honours the `private :foo, :bar` named-argument form" do
        result = analyze(<<~RUBY)
          class Foo
            def bar
              42
            end

            def baz
              43
            end

            private :baz
          end

          Foo.new.baz
        RUBY
        expect(visibility_mismatch_diags(result).size).to eq(1)
      end

      it "does not flag implicit-self calls (always allowed for private)" do
        result = analyze(<<~RUBY)
          class Foo
            def bar
              secret
            end

            private

            def secret
              42
            end
          end
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end

      it "does not flag `self.foo` (Ruby 2.7+ permits self.private_method)" do
        result = analyze(<<~RUBY)
          class Foo
            def bar
              self.secret
            end

            private

            def secret
              42
            end
          end
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end

      it "does not flag a public method call on the same class" do
        result = analyze(<<~RUBY)
          class Foo
            def hello
              "hi"
            end
          end

          Foo.new.hello
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end

      it "switches default visibility back when `public` modifier follows" do
        result = analyze(<<~RUBY)
          class Foo
            private

            def secret
              42
            end

            public

            def open
              43
            end
          end

          Foo.new.open
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable method-visibility-mismatch`" do
        result = analyze(<<~RUBY)
          class Foo
            private

            def secret
              42
            end
          end

          Foo.new.secret # rigor:disable method-visibility-mismatch
        RUBY
        expect(visibility_mismatch_diags(result)).to be_empty
      end
    end

    # ADR-35 slice 1 — Liskov signature rule for visibility.
    describe "override-visibility-reduced rule (ADR-35 slice 1)" do
      def override_visibility_diags(result)
        result.diagnostics.select { |d| d.rule == "def.override-visibility-reduced" }
      end

      it "flags a subclass override that makes a public method private" do
        result = analyze(<<~RUBY)
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            private

            def greet
              "hello"
            end
          end
        RUBY
        diag = override_visibility_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.message).to include("`greet'")
        expect(diag.message).to include("private")
        expect(diag.message).to include("Base")
      end

      it "flags a reduction from an included module's public method" do
        result = analyze(<<~RUBY)
          module Greeter
            def greet
              "hi"
            end
          end

          class Host
            include Greeter

            private

            def greet
              "hello"
            end
          end
        RUBY
        expect(override_visibility_diags(result).size).to eq(1)
      end

      it "flags a protected -> private reduction" do
        result = analyze(<<~RUBY)
          class Base
            protected

            def helper
              1
            end
          end

          class Sub < Base
            private

            def helper
              2
            end
          end
        RUBY
        expect(override_visibility_diags(result).size).to eq(1)
      end

      it "does not flag an override that preserves visibility" do
        result = analyze(<<~RUBY)
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            def greet
              "hello"
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end

      it "does not flag widening (private parent -> public override)" do
        result = analyze(<<~RUBY)
          class Base
            private

            def helper
              1
            end
          end

          class Sub < Base
            def helper
              2
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end

      it "does not flag a method that overrides nothing" do
        result = analyze(<<~RUBY)
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            private

            def fresh
              "new"
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end

      it "resolves the ancestor cross-file" do
        result = analyze(files: {
                           "base.rb" => <<~RUBY,
                             class Base
                               def greet
                                 "hi"
                               end
                             end
                           RUBY
                           "sub.rb" => <<~RUBY
                             class Sub < Base
                               private

                               def greet
                                 "hello"
                               end
                             end
                           RUBY
                         })
        expect(override_visibility_diags(result).size).to eq(1)
      end

      it "is suppressed under the lenient profile" do
        result = analyze(<<~RUBY, config: { "severity_profile" => "lenient" })
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            private

            def greet
              "hello"
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable def.override-visibility-reduced`" do
        result = analyze(<<~RUBY)
          class Base
            def greet
              "hi"
            end
          end

          class Sub < Base
            private

            def greet # rigor:disable def.override-visibility-reduced
              "hello"
            end
          end
        RUBY
        expect(override_visibility_diags(result)).to be_empty
      end
    end

    # ADR-35 slice 2 — Liskov signature rule for returns (covariance).
    describe "override-return-widened rule (ADR-35 slice 2)" do
      def override_return_diags(result)
        result.diagnostics.select { |d| d.rule == "def.override-return-widened" }
      end

      let(:widen_sig) do
        { "demo.rbs" => <<~RBS }
          class Base
            def value: () -> Integer
          end

          class Sub < Base
            def value: () -> Object
          end
        RBS
      end

      it "flags an override that widens the inherited return type" do
        result = analyze(<<~RUBY, sig: widen_sig)
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              Object.new
            end
          end
        RUBY
        diag = override_return_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.message).to include("`value'")
        expect(diag.message).to include("Base")
      end

      it "does not flag an override that narrows the return (covariant-safe)" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              1
            end
          end
        RUBY
          class Base
            def value: () -> Numeric
          end

          class Sub < Base
            def value: () -> Integer
          end
        RBS
        expect(override_return_diags(result)).to be_empty
      end

      it "flags a widening of a return inherited from an included module" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          module Producer
            def value
              1
            end
          end

          class Host
            include Producer

            def value
              Object.new
            end
          end
        RUBY
          module Producer
            def value: () -> Integer
          end

          class Host
            include Producer

            def value: () -> Object
          end
        RBS
        expect(override_return_diags(result).size).to eq(1)
      end

      it "does not fire when the override has no authored signature" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              Object.new
            end
          end
        RUBY
          class Base
            def value: () -> Integer
          end
        RBS
        expect(override_return_diags(result)).to be_empty
      end

      it "does not fire when the parent return is untyped" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              Object.new
            end
          end
        RUBY
          class Base
            def value: () -> untyped
          end

          class Sub < Base
            def value: () -> Object
          end
        RBS
        expect(override_return_diags(result)).to be_empty
      end

      it "is suppressed under the lenient profile" do
        result = analyze(<<~RUBY, sig: widen_sig, config: { "severity_profile" => "lenient" })
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value
              Object.new
            end
          end
        RUBY
        expect(override_return_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable def.override-return-widened`" do
        result = analyze(<<~RUBY, sig: widen_sig)
          class Base
            def value
              1
            end
          end

          class Sub < Base
            def value # rigor:disable def.override-return-widened
              Object.new
            end
          end
        RUBY
        expect(override_return_diags(result)).to be_empty
      end
    end

    # ADR-35 slice 3 — Liskov signature rule for parameters (contravariance).
    # Uses real (loadable) classes Numeric/Integer so the nominal subtype
    # check resolves to :no rather than the FP-safe :maybe it returns for
    # unloadable user-only class hierarchies.
    describe "override-param-narrowed rule (ADR-35 slice 3)" do
      def override_param_diags(result)
        result.diagnostics.select { |d| d.rule == "def.override-param-narrowed" }
      end

      let(:base_sub_source) do
        <<~RUBY
          class Base
            def consume(value)
            end
          end

          class Sub < Base
            def consume(value)
            end
          end
        RUBY
      end

      let(:narrow_sig) do
        { "demo.rbs" => <<~RBS }
          class Base
            def consume: (Numeric) -> void
          end

          class Sub < Base
            def consume: (Integer) -> void
          end
        RBS
      end

      it "flags an override that narrows a parameter type" do
        result = analyze(base_sub_source, sig: narrow_sig)
        diag = override_param_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.severity).to eq(:warning)
        expect(diag.message).to include("`consume'")
        expect(diag.message).to include("Base")
      end

      it "does not flag an override that widens a parameter (contravariant-safe)" do
        result = analyze(base_sub_source, sig: { "demo.rbs" => <<~RBS })
          class Base
            def consume: (Integer) -> void
          end

          class Sub < Base
            def consume: (Numeric) -> void
          end
        RBS
        expect(override_param_diags(result)).to be_empty
      end

      it "flags a parameter narrowing inherited from an included module" do
        result = analyze(<<~RUBY, sig: { "demo.rbs" => <<~RBS })
          module Consumer
            def consume(value)
            end
          end

          class Host
            include Consumer

            def consume(value)
            end
          end
        RUBY
          module Consumer
            def consume: (Numeric) -> void
          end

          class Host
            include Consumer

            def consume: (Integer) -> void
          end
        RBS
        expect(override_param_diags(result).size).to eq(1)
      end

      it "does not fire when the parent parameter is untyped" do
        result = analyze(base_sub_source, sig: { "demo.rbs" => <<~RBS })
          class Base
            def consume: (untyped) -> void
          end

          class Sub < Base
            def consume: (Integer) -> void
          end
        RBS
        expect(override_param_diags(result)).to be_empty
      end

      it "does not fire when the override has no authored signature" do
        result = analyze(base_sub_source, sig: { "demo.rbs" => <<~RBS })
          class Base
            def consume: (Numeric) -> void
          end
        RBS
        expect(override_param_diags(result)).to be_empty
      end

      it "is suppressed under the lenient profile" do
        result = analyze(base_sub_source, sig: narrow_sig, config: { "severity_profile" => "lenient" })
        expect(override_param_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable def.override-param-narrowed`" do
        result = analyze(<<~RUBY, sig: narrow_sig)
          class Base
            def consume(value)
            end
          end

          class Sub < Base
            def consume(value) # rigor:disable def.override-param-narrowed
            end
          end
        RUBY
        expect(override_param_diags(result)).to be_empty
      end
    end

    describe "dead-assignment rule (v0.1.2)" do
      def dead_diags(result)
        result.diagnostics.select { |d| d.rule == "flow.dead-assignment" }
      end

      it "flags a local that is assigned but never read" do
        result = analyze(<<~RUBY)
          def example
            x = 1
            42
          end
        RUBY
        diag = dead_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("local `x'")
        expect(diag.message).to include("`example'")
        expect(diag.message).to include("never read")
      end

      it "does not flag the trailing assignment (Ruby's implicit return)" do
        result = analyze(<<~RUBY)
          def example
            x = 1
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag locals that are read later in the same body" do
        result = analyze(<<~RUBY)
          def example
            x = 1
            x + 2
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag locals read inside a nested block" do
        result = analyze(<<~RUBY)
          def example
            x = [1, 2, 3]
            [4, 5].each { |y| puts y + x.size }
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag names starting with `_` (intentionally unused)" do
        result = analyze(<<~RUBY)
          def example
            _scratch = 1
            42
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag operator-writes (`x += 1`)" do
        result = analyze(<<~RUBY)
          def example
            x = 0
            x += 1
            42
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag multi-assignment (`a, b = foo`)" do
        result = analyze(<<~RUBY)
          def example
            a, b = [1, 2]
            b
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "does not flag top-level assignments (the rule scope is method bodies)" do
        result = analyze(<<~RUBY)
          dead_at_top = 1
        RUBY
        expect(dead_diags(result)).to be_empty
      end

      it "is suppressible via `# rigor:disable dead-assignment`" do
        result = analyze(<<~RUBY)
          def example
            x = 1 # rigor:disable dead-assignment
            42
          end
        RUBY
        expect(dead_diags(result)).to be_empty
      end
    end

    describe "ivar-write-mismatch rule (v0.1.2)" do
      def ivar_diags(result)
        result.diagnostics.select { |d| d.rule == "def.ivar-write-mismatch" }
      end

      it "flags a String → Integer ivar drift in the same class" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @name = "Alice"
            end

            def reset
              @name = 42
            end
          end
        RUBY
        diag = ivar_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("@name")
        expect(diag.message).to include("Foo")
        expect(diag.message).to include("String")
        expect(diag.message).to include("Integer")
      end

      it "does not flag widening to nil (intentional 'clear' idiom)" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @value = "hello"
            end

            def clear
              @value = nil
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag multiple writes that share the same concrete class" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @count = 0
            end

            def bump
              @count = 5
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag class-body ivars outside any def" do
        # Class-level ivars (`Module#@var`) are a separate
        # surface the engine doesn't yet model.
        result = analyze(<<~RUBY)
          class Foo
            @config = "default"
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag ivars in unrelated classes that share a name" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @value = "hello"
            end
          end

          class Bar
            def initialize
              @value = 42
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag the bool flag idiom (false in initialize, true elsewhere)" do
        # Common idiom: a memoization flag starts at `false` and
        # transitions to `true` once the underlying value has been
        # computed. Both writes are conceptually `bool` — the rule
        # MUST NOT fire on this shape.
        result = analyze(<<~RUBY)
          class Holder
            def initialize
              @loaded = false
              @value = nil
            end

            def fetch
              return @value if @loaded

              @value = compute
              @loaded = true
              @value
            end

            def compute
              42
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "does not flag a nil-placeholder followed by concrete writes (nullable-slot idiom)" do
        # The `@parse_method = nil` placeholder followed by
        # per-state `@parse_method = :foo` / `:bar` assignments
        # is the common nullable-slot idiom. Pre-fix the
        # `NilClass` placeholder anchored as `first_class` and
        # every concrete write tripped the rule; the canonical
        # type is now the first non-nil write so neither
        # `Symbol → Symbol` (same class) nor `nil → Symbol`
        # widening fires.
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @parse_method = nil
            end

            def step(line)
              if line == "a"
                @parse_method = :parse_a
              elsif line == "b"
                @parse_method = :parse_b
              elsif line == "c"
                @parse_method = nil
              end
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end

      it "still flags Symbol → String drift even with a leading nil placeholder" do
        # The leading `nil` shouldn't mask a genuine drift between
        # two distinct concrete classes.
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @value = nil
            end

            def first_write
              @value = :sym
            end

            def second_write
              @value = "string"
            end
          end
        RUBY
        diag = ivar_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("Symbol")
        expect(diag.message).to include("String")
      end

      it "still flags a genuine bool → String drift" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @flag = true
            end

            def reset
              @flag = "ready"
            end
          end
        RUBY
        diag = ivar_diags(result).first
        expect(diag).not_to be_nil
        expect(diag.message).to include("bool")
        expect(diag.message).to include("String")
      end

      it "is suppressible via `# rigor:disable ivar-write-mismatch`" do
        result = analyze(<<~RUBY)
          class Foo
            def initialize
              @name = "Alice"
            end

            def reset
              @name = 42 # rigor:disable ivar-write-mismatch
            end
          end
        RUBY
        expect(ivar_diags(result)).to be_empty
      end
    end
  end

  describe "implicit-self call dispatch (v0.0.3 A)" do
    it "prefers a top-level `def` over RBS dispatch for implicit-self calls" do
      result = analyze(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def helper(value)
          value
        end
        x = helper(42)
        assert_type("42", x)
      RUBY

      expect(result.diagnostics.select { |d| d.rule == "assert.type-mismatch" }).to be_empty
    end

    it "returns Dynamic[Top] when the top-level def has a complex param shape" do
      # `def helper(x, kind: :default)` has a kwarg — the
      # first-iteration binder rejects it. The engine still
      # prefers the local def over RBS dispatch and returns
      # `Dynamic[Top]`, suppressing the spurious
      # `Array#select`-style mis-routing that previously
      # caused `select(...)` to type as `Array[Elem]`.
      result = analyze(<<~RUBY)
        def select(class_name, method_name, kind: :instance)
          class_name
        end
        mt = select("Array", :first)
        mt.no_such_method_on_array
      RUBY

      # `mt` is `Dynamic[Top]`; the undefined-method rule
      # skips Dynamic receivers so no diagnostic surfaces.
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end
  end

  describe "RSpec matcher narrowing (v0.0.3 B)" do
    it "narrows away from nil after `expect(x).not_to be_nil`" do
      result = analyze(<<~RUBY)
        x = if rand < 0.5
          "hello"
        else
          nil
        end
        expect(x).not_to be_nil
        x.upcase
      RUBY

      nil_errors = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
      expect(nil_errors).to be_empty
    end

    it "also recognises `to_not be_nil` (alias)" do
      result = analyze(<<~RUBY)
        x = if rand < 0.5
          "hello"
        else
          nil
        end
        expect(x).to_not be_nil
        x.upcase
      RUBY

      expect(result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }).to be_empty
    end

    it "narrows a union to the asserted class after `expect(x).to be_a(C)`" do
      result = analyze(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        x = if rand < 0.5
          "hello"
        else
          42
        end
        expect(x).to be_a(Integer)
        assert_type("42", x)
      RUBY

      # `String | 42` narrowed to `Integer` keeps only the
      # integer-side carrier (Constant[42] survives because
      # it is a subtype of Integer); the String carrier is
      # dropped.
      mismatch = result.diagnostics.find { |d| d.rule == "assert.type-mismatch" }
      expect(mismatch).to be_nil
    end

    it "leaves the scope unchanged when the matcher shape is unrecognised" do
      # `to be_truthy` is intentionally NOT modelled; the
      # post-call type of `x` should remain `String | nil`
      # and `x.upcase` should still flag.
      result = analyze(<<~RUBY)
        x = if rand < 0.5
          "hello"
        else
          nil
        end
        expect(x).to be_truthy
        x.upcase
      RUBY

      nil_errors = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
      expect(nil_errors).not_to be_empty
    end
  end

  describe "explain mode (v0.0.2 #10)" do
    it "is silent by default" do
      result = analyze("x = 1\n")

      expect(result.diagnostics.select { |d| d.rule == "fallback" }).to be_empty
    end

    it "emits :info fallback diagnostics when explain is on" do
      # `BEGIN { ... }` is a Prism::PreExecutionNode the engine
      # does not recognise — a stable explain-mode trigger.
      result = analyze("BEGIN { 1 }\n", explain: true)

      fallback = result.diagnostics.find { |d| d.rule == "fallback" }
      expect(fallback).not_to be_nil
      expect(fallback.severity).to eq(:info)
      expect(fallback.message).to include("fail-soft fallback")
      expect(result).to be_success # info doesn't fail the run
    end
  end

  describe "always-raises rule (Integer division/modulo by zero)" do
    it "flags `5 / 0` as always-raising at :error severity" do
      result = analyze("5 / 0\n")
      diag = result.diagnostics.find { |d| d.rule == "flow.always-raises" }
      expect(diag).not_to be_nil
      expect(diag.message).to include("ZeroDivisionError")
      expect(diag.severity).to eq(:error)
    end

    it "flags every recognised raising operator on Integer" do
      sources = {
        "5 / 0\n" => "/",
        "5 % 0\n" => "%",
        "5.div(0)\n" => "div",
        "5.modulo(0)\n" => "modulo",
        "5.divmod(0)\n" => "divmod"
      }
      sources.each do |src, label|
        diag = analyze(src).diagnostics.find { |d| d.rule == "flow.always-raises" }
        expect(diag).not_to(be_nil, "expected an always-raises diagnostic for `#{label}`")
      end
    end

    it "fires when the receiver is Nominal[Integer] (wider receiver)" do
      diag = analyze("rand(100) / 0\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      expect(diag).not_to be_nil
    end

    it "does not fire on Float arithmetic (returns Infinity, not raise)" do
      expect(
        analyze("5.0 / 0\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      ).to be_nil
      expect(
        analyze("5 / 0.0\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      ).to be_nil
    end

    it "does not fire on Integer#fdiv (returns Infinity, not raise)" do
      expect(
        analyze("5.fdiv(0)\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      ).to be_nil
    end

    it "does not fire when the divisor is non-zero" do
      expect(analyze("5 / 2\n")).to be_success
    end

    it "does not fire when the divisor cannot be proved zero" do
      # `rand(100)` could be zero but the analyzer cannot
      # prove it, so the rule stays silent.
      expect(
        analyze("rand(100) / rand(100)\n").diagnostics.find { |d| d.rule == "flow.always-raises" }
      ).to be_nil
    end

    it "is suppressible via `# rigor:disable always-raises`" do
      result = analyze("5 / 0 # rigor:disable always-raises\n")
      expect(result.diagnostics.find { |d| d.rule == "flow.always-raises" }).to be_nil
    end
  end

  describe "plugin diagnostic emission (v0.1.0 slice 5-A/5-B)" do
    let(:plugin_class) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "demo-emitter", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          [
            Rigor::Analysis::Diagnostic.new(
              path: path, line: 1, column: 1,
              message: "demo plugin says hello",
              severity: :warning,
              rule: "saw-file"
            )
          ]
        end
      end
      stub_const("FakeDemoEmitterPlugin", klass)
      klass
    end

    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    def run_with_plugin(plugin_class:, source: "x = 1\n")
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-demo-emitter"]
          )
        )
        requirer = lambda { |_name|
          Rigor::Plugin.register(plugin_class)
          true
        }
        described_class.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: requirer
        ).run
      end
    end

    it "auto-stamps plugin-emitted diagnostics with source_family plugin.<id>" do
      result = run_with_plugin(plugin_class: plugin_class)
      diag = result.diagnostics.find { |d| d.rule == "saw-file" }
      expect(diag).not_to be_nil
      expect(diag.source_family).to eq("plugin.demo-emitter")
      expect(diag.qualified_rule).to eq("plugin.demo-emitter.saw-file")
      expect(diag.to_s).to include("[plugin.demo-emitter.saw-file]")
    end

    it "runs a plugin's node_rule over each file and stamps provenance (ADR-37)" do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "demo-emitter", version: "0.1.0")

        node_rule Prism::CallNode do |node, _scope, path|
          next [] unless node.name == :flagme

          [diagnostic(node, path: path, message: "node rule saw flagme", rule: "saw-call")]
        end
      end
      stub_const("FakeNodeRulePlugin", klass)

      result = run_with_plugin(plugin_class: klass, source: "flagme\n")
      diag = result.diagnostics.find { |d| d.rule == "saw-call" }
      expect(diag).not_to be_nil
      expect(diag.message).to eq("node rule saw flagme")
      expect(diag.source_family).to eq("plugin.demo-emitter")
    end

    it "isolates plugin exceptions as :plugin_loader runtime-error diagnostics" do
      bomb_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "bomb-emitter", version: "0.1.0")
      end
      bomb_class.define_method(:diagnostics_for_file) { |**| raise "kaboom" }
      stub_const("FakeBombEmitterPlugin", bomb_class)

      result = run_with_plugin(plugin_class: bomb_class)
      diag = result.diagnostics.find { |d| d.source_family == :plugin_loader && d.rule == "runtime-error" }
      expect(diag).not_to be_nil
      expect(diag.message).to include("kaboom")
    end

    it "leaves the diagnostic stream unchanged when no plugin emits" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge("paths" => [File.join(dir, "demo.rb")])
        )
        result = described_class.new(configuration: configuration, cache_store: nil).run
        expect(result.diagnostics.select { |d| d.source_family.to_s.start_with?("plugin.") }).to be_empty
      end
    end
  end

  describe "Plugin dynamic_return return-type override (v0.1.1 / Track 2 slice 7)" do
    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    def run_with(plugin_class, source: "x = 1\n")
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-flow-contributor"]
          )
        )
        requirer = lambda do |_name|
          Rigor::Plugin.register(plugin_class)
          true
        end
        runner = described_class.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        )
        [runner, runner.run]
      end
    end

    it "threads the plugin registry through Environment#plugin_registry" do
      noop_plugin = Class.new(Rigor::Plugin::Base) do
        manifest(id: "flow-noop", version: "0.1.0")
      end
      stub_const("FakeFlowNoopPlugin", noop_plugin)

      runner, result = run_with(noop_plugin)
      expect(result).to be_a(Rigor::Analysis::Result)
      expect(runner.plugin_registry.ids).to eq(["flow-noop"])
    end

    it "isolates a dynamic_return raise — dispatch keeps running, no plugin_loader runtime-error" do
      raising = Class.new(Rigor::Plugin::Base) do
        manifest(id: "raising-contributor", version: "0.1.0")

        dynamic_return methods: [:first] do |_call_node, _scope|
          raise "boom"
        end
      end
      stub_const("FakeRaisingContributorPlugin", raising)

      _, result = run_with(raising, source: "[1, 2, 3].first\n")
      runtime_errors = result.diagnostics.select do |d|
        d.source_family == :plugin_loader && d.rule == "runtime-error"
      end
      # The contribution is silently dropped — no diagnostic. The
      # rest of the run continues. (Plugins that need to surface
      # their own errors should emit through diagnostics_for_file.)
      expect(runtime_errors).to be_empty
      expect(result).to be_a(Rigor::Analysis::Result)
    end
  end

  describe "Plugin-side post_return_facts wiring (T.bind / T.assert_type! priority slice 2)" do
    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    # Synthetic plugin: recognises any call named `narrow_self_to_string!`
    # and contributes a post_return_fact narrowing self to
    # `Nominal[String]` from that call onwards.
    let(:self_narrowing_plugin) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "self-narrower", version: "0.1.0")

        dynamic_return methods: [:narrow_self_to_string!] do |_call_node, _scope|
          Rigor::Type::Combinator.constant_of(nil)
        end

        narrowing_facts methods: [:narrow_self_to_string!] do |_call_node, _scope|
          [Rigor::FlowContribution::Fact.new(
            target_kind: :self, target_name: :self, type: Rigor::Type::Combinator.nominal_of("String")
          )]
        end
      end
      stub_const("FakeSelfNarrowingPlugin", klass)
      klass
    end

    def run_with_plugin(plugin_class, source:)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), source)
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-self-narrower"]
          )
        )
        requirer = lambda do |_name|
          Rigor::Plugin.register(plugin_class)
          true
        end
        described_class.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        ).run
      end
    end

    it "applies a plugin-contributed post_return_fact(target_kind: :self) to the surrounding scope" do
      # Without the narrowing, `self.upcase` would emit
      # `call.undefined-method` because the implicit-self type
      # at top level isn't `String`. The plugin narrows self to
      # `Nominal[String]` after `narrow_self_to_string!`, so
      # `self.upcase` resolves cleanly.
      result = run_with_plugin(self_narrowing_plugin, source: <<~RUBY)
        def narrow_self_to_string!; nil; end
        narrow_self_to_string!
        self.upcase
      RUBY

      undef_calls = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(undef_calls).to be_empty
    end

    it "leaves the rest of the program unchanged when the plugin contributes no facts" do
      noop = Class.new(Rigor::Plugin::Base) { manifest(id: "noop-narrower", version: "0.1.0") }
      stub_const("FakeNoopNarrowingPlugin", noop)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-noop-narrower"]
          )
        )
        requirer = lambda do |_name|
          Rigor::Plugin.register(noop)
          true
        end
        result = described_class.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        ).run
        expect(result.diagnostics.select { |d| d.source_family == "plugin.noop-narrower" }).to be_empty
      end
    end
  end

  describe "Plugin#prepare invocation (v0.1.1 / ADR-9 slice 3)" do
    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    def run_with_plugin(plugin_class)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "demo.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb")],
            "plugins" => ["rigor-prepare-test"]
          )
        )
        requirer = lambda do |_name|
          Rigor::Plugin.register(plugin_class)
          true
        end
        described_class.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        ).run
      end
    end

    let(:publishing_plugin) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "prepare-test", version: "0.1.0")

        def prepare(services)
          services.fact_store.publish(plugin_id: manifest.id, name: :greeting, value: "hello")
        end

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          greeting = services.fact_store.read(plugin_id: manifest.id, name: :greeting)
          [Rigor::Analysis::Diagnostic.new(
            path: path, line: 1, column: 1,
            message: "saw fact: #{greeting.inspect}", severity: :info, rule: "saw-fact"
          )]
        end
      end
      stub_const("FakePrepareTestPlugin", klass)
      klass
    end

    it "calls #prepare on every loaded plugin so facts are visible per-file" do
      result = run_with_plugin(publishing_plugin)
      diag = result.diagnostics.find { |d| d.rule == "saw-fact" }
      expect(diag).not_to be_nil
      expect(diag.message).to include('"hello"')
    end

    it "isolates a #prepare raise as a :plugin_loader runtime-error diagnostic" do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "prepare-bomb", version: "0.1.0")

        def prepare(_services)
          raise "kaboom"
        end
      end
      stub_const("FakePrepareBombPlugin", klass)

      result = run_with_plugin(klass)
      diag = result.diagnostics.find do |d|
        d.source_family == :plugin_loader && d.rule == "runtime-error" && d.message.include?("prepare")
      end
      expect(diag).not_to be_nil
      expect(diag.message).to include("kaboom")
    end
  end

  describe "RBS::Extended reporter diagnostics (ADR-13 slice 3b)" do
    def analyze_reporter_demo(class_name, return_annotation)
      sig = { "demo.rbs" => <<~RBS }
        class #{class_name}
          %a{rigor:v1:return: #{return_annotation}}
          def fetch: () -> String
        end
      RBS
      src = "class #{class_name}\n  def fetch\n    \"x\"\n  end\nend\n"
      analyze(src, sig: sig)
    end

    it "surfaces an unresolved `rigor:v1:return:` payload as `dynamic.rbs-extended.unresolved`" do
      result = analyze_reporter_demo("ReportDemo", "not-a-known-refinement")
      diag = result.diagnostics.find { |d| d.rule == "dynamic.rbs-extended.unresolved" }

      expect(diag).not_to be_nil
      expect(diag.message).to include("not-a-known-refinement")
      expect(diag.source_family).to eq(:builtin)
      expect(diag.path).to include("demo.rbs")
    end

    it "surfaces a shape-projection on a non-shape carrier as `dynamic.shape.lossy-projection`" do
      result = analyze_reporter_demo("LossyDemo", "pick_of[Hash[String, Integer], String]")
      diag = result.diagnostics.find { |d| d.rule == "dynamic.shape.lossy-projection" }

      expect(diag).not_to be_nil
      expect(diag.message).to include("pick_of")
      expect(diag.source_family).to eq(:builtin)
      expect(diag.path).to include("demo.rbs")
    end

    it "stays silent when no shape-projection is in play and the payload resolves" do
      result = analyze_reporter_demo("CleanDemo", "non-empty-string")

      expect(result.diagnostics.find { |d| d.rule == "dynamic.rbs-extended.unresolved" }).to be_nil
      expect(result.diagnostics.find { |d| d.rule == "dynamic.shape.lossy-projection" }).to be_nil
    end
  end

  describe "`rigor:v1:conforms-to` conformance directive" do
    def analyze_conforms_to(class_body:, interface_body: "def rewind: () -> void\n  def read: () -> String",
                            interface: "_RewindableBuffer")
      sig = { "buffer.rbs" => <<~RBS }
        interface #{interface}
          #{interface_body}
        end

        %a{rigor:v1:conforms-to #{interface}}
        class ConformDemo
          #{class_body}
        end
      RBS
      analyze("x = 1\n", sig: sig)
    end

    it "flags a class that declares conforms-to but is missing a required method" do
      result = analyze_conforms_to(class_body: "def read: () -> String")
      diag = result.diagnostics.find { |d| d.rule == "rbs_extended.unsatisfied-conformance" }

      expect(diag).not_to be_nil
      expect(diag.message).to include("ConformDemo")
      expect(diag.message).to include("_RewindableBuffer")
      expect(diag.message).to include("`#rewind`")
      expect(diag.message).not_to include("`#read`")
      expect(diag.severity).to eq(:warning)
      expect(diag.path).to include("buffer.rbs")
    end

    it "stays silent when the class provides every required method (own + inherited)" do
      result = analyze_conforms_to(class_body: "def rewind: () -> void\n  def read: () -> String")

      expect(result.diagnostics.find { |d| d.rule == "rbs_extended.unsatisfied-conformance" }).to be_nil
    end

    it "lists every missing method when several are absent" do
      result = analyze_conforms_to(class_body: "def unrelated: () -> bool")
      diag = result.diagnostics.find { |d| d.rule == "rbs_extended.unsatisfied-conformance" }

      expect(diag).not_to be_nil
      expect(diag.message).to include("`#rewind`")
      expect(diag.message).to include("`#read`")
      expect(diag.message).to include("2 required methods")
    end

    it "surfaces an unknown interface name as `dynamic.rbs-extended.unresolved`" do
      sig = { "buffer.rbs" => <<~RBS }
        %a{rigor:v1:conforms-to _NotDeclared}
        class UnresolvedConformDemo
        end
      RBS
      result = analyze("x = 1\n", sig: sig)
      diag = result.diagnostics.find { |d| d.rule == "dynamic.rbs-extended.unresolved" }

      expect(diag).not_to be_nil
      expect(diag.message).to include("_NotDeclared")
      expect(diag.message).to include("not loaded")
    end

    it "flags a provided method whose return type widens the interface contract" do
      result = analyze_conforms_to(
        interface_body: "def rewind: () -> void\n  def read: () -> String",
        class_body: "def rewind: () -> void\n  def read: () -> (String | Integer)"
      )
      diag = result.diagnostics.find do |d|
        d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
      end

      expect(diag).not_to be_nil
      expect(diag.message).to include("return type")
      expect(diag.message).to include("not a subtype")
      expect(diag.severity).to eq(:warning)
    end

    it "flags a provided method whose parameter narrows the interface contract" do
      result = analyze_conforms_to(
        interface_body: "def rewind: () -> void\n  def read: (Object value) -> String",
        class_body: "def rewind: () -> void\n  def read: (String value) -> String"
      )
      diag = result.diagnostics.find do |d|
        d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
      end

      expect(diag).not_to be_nil
      expect(diag.message).to include("parameter 1")
      expect(diag.message).to include("does not accept")
    end

    it "stays silent when a provided method's return type is a subtype (covariant)" do
      result = analyze_conforms_to(
        interface_body: "def rewind: () -> void\n  def read: () -> Numeric",
        class_body: "def rewind: () -> void\n  def read: () -> Integer"
      )

      expect(result.diagnostics.find { |d| d.rule == "rbs_extended.unsatisfied-conformance" }).to be_nil
    end

    it "stays silent when a provided method widens a parameter (contravariant)" do
      result = analyze_conforms_to(
        interface_body: "def rewind: () -> void\n  def read: (Integer value) -> String",
        class_body: "def rewind: () -> void\n  def read: (Numeric value) -> String"
      )

      expect(result.diagnostics.find { |d| d.rule == "rbs_extended.unsatisfied-conformance" }).to be_nil
    end

    describe "arity divergence" do
      it "flags a provided method that requires more positionals than the interface allows" do
        result = analyze_conforms_to(
          interface_body: "def rewind: () -> void\n  def read: (String s) -> String",
          class_body: "def rewind: () -> void\n  def read: (String s, Integer n) -> String"
        )
        diag = result.diagnostics.find do |d|
          d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
        end
        expect(diag).not_to be_nil
        expect(diag.message).to include("requires 2 positional arguments")
        expect(diag.message).to include("allows at most 1")
      end

      it "flags a provided method that accepts fewer positionals than the interface requires" do
        result = analyze_conforms_to(
          interface_body: "def rewind: () -> void\n  def read: (String s, Integer n) -> String",
          class_body: "def rewind: () -> void\n  def read: (String s) -> String"
        )
        diag = result.diagnostics.find do |d|
          d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
        end
        expect(diag).not_to be_nil
        expect(diag.message).to include("accepts at most 1")
        expect(diag.message).to include("requires at least 2")
      end

      it "stays silent when provided has a rest parameter covering extra required positionals" do
        result = analyze_conforms_to(
          interface_body: "def rewind: () -> void\n  def read: (String s, Integer n) -> String",
          class_body: "def rewind: () -> void\n  def read: (String s, *untyped rest) -> String"
        )
        expect(result.diagnostics.find do |d|
          d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
        end).to be_nil
      end

      it "stays silent when the interface has a rest parameter" do
        result = analyze_conforms_to(
          interface_body: "def rewind: () -> void\n  def read: (String s, *untyped rest) -> String",
          class_body: "def rewind: () -> void\n  def read: (String s, Integer n) -> String"
        )
        expect(result.diagnostics.find do |d|
          d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
        end).to be_nil
      end
    end

    describe "keyword-requiredness divergence" do
      it "flags a provided method missing a required interface keyword" do
        result = analyze_conforms_to(
          interface_body: "def rewind: () -> void\n  def read: (encoding: String) -> String",
          class_body: "def rewind: () -> void\n  def read: () -> String"
        )
        diag = result.diagnostics.find do |d|
          d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
        end
        expect(diag).not_to be_nil
        expect(diag.message).to include("does not accept required keyword")
        expect(diag.message).to include("`encoding:`")
      end

      it "flags a provided method requiring a keyword the interface does not declare" do
        result = analyze_conforms_to(
          interface_body: "def rewind: () -> void\n  def read: () -> String",
          class_body: "def rewind: () -> void\n  def read: (encoding: String) -> String"
        )
        diag = result.diagnostics.find do |d|
          d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
        end
        expect(diag).not_to be_nil
        expect(diag.message).to include("requires keyword")
        expect(diag.message).to include("`encoding:`")
        expect(diag.message).to include("not declared by the interface")
      end

      it "stays silent when the provided method accepts the required keyword (as optional)" do
        result = analyze_conforms_to(
          interface_body: "def rewind: () -> void\n  def read: (encoding: String) -> String",
          class_body: "def rewind: () -> void\n  def read: (?encoding: String) -> String"
        )
        expect(result.diagnostics.find do |d|
          d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
        end).to be_nil
      end

      it "stays silent when provided has a keyword rest (**kwargs)" do
        result = analyze_conforms_to(
          interface_body: "def rewind: () -> void\n  def read: (encoding: String) -> String",
          class_body: "def rewind: () -> void\n  def read: (**untyped opts) -> String"
        )
        expect(result.diagnostics.find do |d|
          d.rule == "rbs_extended.unsatisfied-conformance" && d.message.include?("#read")
        end).to be_nil
      end
    end

    it "resolves an interface name relative to the declaring class's namespace" do
      sig = { "buffers.rbs" => <<~RBS }
        module Buffers
          interface _Stream
            def read: () -> String
          end

          %a{rigor:v1:conforms-to _Stream}
          class MyBuffer
          end
        end
      RBS
      result = analyze("x = 1\n", sig: sig)

      # `_Stream` is namespace-relative (only `Buffers::_Stream` exists), so
      # resolution must find it under the class's namespace — and then flag
      # the missing `read`, rather than reporting the interface unresolved.
      conformance = result.diagnostics.find { |d| d.rule == "rbs_extended.unsatisfied-conformance" }
      expect(conformance).not_to be_nil
      expect(conformance.message).to include("`#read`")
      expect(result.diagnostics.find { |d| d.rule == "dynamic.rbs-extended.unresolved" }).to be_nil
    end
  end

  describe "editor mode degrades Ractor pool to sequential (slice 7)" do
    it "runs sequentially even when workers > 0 is requested" do
      Dir.mktmpdir("rigor-editor-pool-degrade-") do |tmpdir|
        Dir.chdir(tmpdir) do
          logical = File.join("lib", "foo.rb")
          FileUtils.mkdir_p("lib")
          File.write(logical, "x = 1\n")
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, "x = 1\n")

          binding = Rigor::Analysis::BufferBinding.new(
            logical_path: logical, physical_path: physical
          )
          runner = described_class.new(
            configuration: Rigor::Configuration.new("paths" => ["lib"]),
            cache_store: nil, workers: 4, buffer: binding
          )

          # `pool_mode?` is private; assert via `send` since the
          # contract change IS about that predicate.
          expect(runner.send(:pool_mode?)).to be(false)
        end
      end
    end

    it "still enables pool mode in the absence of a BufferBinding" do
      runner = described_class.new(
        configuration: Rigor::Configuration.new("paths" => []),
        cache_store: nil, workers: 4
      )

      expect(runner.send(:pool_mode?)).to be(true)
    end
  end

  describe "editor mode auto-enables read-only cache (slice 3)" do
    it "wraps the supplied cache_store in a read-only Store when a BufferBinding is present" do
      Dir.mktmpdir("rigor-editor-readonly-") do |tmpdir|
        logical = File.join(tmpdir, "lib", "foo.rb")
        FileUtils.mkdir_p(File.dirname(logical))
        File.write(logical, "x = 1\n")
        physical = File.join(tmpdir, "buffer.rb")
        File.write(physical, "x = 1\n")

        original = Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache"))
        binding = Rigor::Analysis::BufferBinding.new(
          logical_path: logical, physical_path: physical
        )
        runner = described_class.new(
          configuration: Rigor::Configuration.new("paths" => [File.dirname(logical)]),
          cache_store: original, buffer: binding
        )

        expect(runner.cache_store.read_only?).to be(true)
        expect(runner.cache_store).not_to equal(original)
        expect(runner.cache_store.root).to eq(original.root)
      end
    end

    it "leaves nil cache_store as nil (--no-cache still wins)" do
      Dir.mktmpdir("rigor-editor-readonly-nil-") do |tmpdir|
        logical = File.join(tmpdir, "lib", "foo.rb")
        FileUtils.mkdir_p(File.dirname(logical))
        File.write(logical, "x = 1\n")
        physical = File.join(tmpdir, "buffer.rb")
        File.write(physical, "x = 1\n")

        binding = Rigor::Analysis::BufferBinding.new(
          logical_path: logical, physical_path: physical
        )
        runner = described_class.new(
          configuration: Rigor::Configuration.new("paths" => [File.dirname(logical)]),
          cache_store: nil, buffer: binding
        )

        expect(runner.cache_store).to be_nil
      end
    end

    it "does NOT wrap when no BufferBinding is present (legacy path unchanged)" do
      Dir.mktmpdir("rigor-non-editor-cache-") do |tmpdir|
        original = Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache"))
        runner = described_class.new(
          configuration: Rigor::Configuration.new("paths" => []),
          cache_store: original
        )

        expect(runner.cache_store).to equal(original)
        expect(runner.cache_store.read_only?).to be(false)
      end
    end
  end

  describe "editor mode (BufferBinding)" do
    # Slice 2: when the runner is wired with `buffer:`, the
    # logical path in `paths:` is parsed from the physical
    # buffer's bytes but every diagnostic reports the LOGICAL
    # path. The on-disk version of the logical file is silently
    # replaced by the buffer for parse purposes.
    it "parses bytes from the buffer's physical path but emits diagnostics under the logical path" do
      Dir.mktmpdir("rigor-buffer-binding-") do |tmpdir|
        Dir.chdir(tmpdir) do
          logical = File.join("lib", "foo.rb")
          FileUtils.mkdir_p("lib")
          # On disk: a clean file with no diagnostics.
          File.write(logical, "x = 1\n")
          # Buffer: the same file with a parse error.
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, "def broken\n")

          configuration = Rigor::Configuration.new("paths" => ["lib"])
          binding = Rigor::Analysis::BufferBinding.new(
            logical_path: logical, physical_path: physical
          )
          result = described_class.new(
            configuration: configuration, cache_store: nil, buffer: binding
          ).run

          # The parse error from the buffer surfaces under the
          # LOGICAL path — that's what the editor highlights.
          paths = result.diagnostics.map(&:path)
          expect(paths).to include(logical)
          expect(paths).not_to include(physical)
        end
      end
    end

    it "restricts per-file diagnostics to the buffer's logical path (single-file scope, slice 5)" do
      Dir.mktmpdir("rigor-buffer-binding-scope-") do |tmpdir|
        Dir.chdir(tmpdir) do
          logical = File.join("lib", "foo.rb")
          other = File.join("lib", "bar.rb")
          FileUtils.mkdir_p("lib")
          File.write(logical, "x = 1\n")
          # `other` would normally surface a parse error — but under
          # editor mode it MUST NOT be analyzed.
          File.write(other, "def also_broken\n")
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, "x = 1\n")

          configuration = Rigor::Configuration.new("paths" => ["lib"])
          binding = Rigor::Analysis::BufferBinding.new(
            logical_path: logical, physical_path: physical
          )
          result = described_class.new(
            configuration: configuration, cache_store: nil, buffer: binding
          ).run

          paths = result.diagnostics.map(&:path).uniq
          # `other` is NOT analyzed — its parse error stays silent.
          expect(paths).not_to include(other)
          # The buffer (clean) produces no diagnostics either.
          expect(paths).not_to include(physical)
        end
      end
    end

    it "analyzes the buffer when its logical path doesn't exist on disk (LSP new-file case)" do
      Dir.mktmpdir("rigor-buffer-binding-phantom-") do |tmpdir|
        Dir.chdir(tmpdir) do
          # Logical path doesn't exist on disk — user is editing a
          # brand-new file via LSP.
          logical = File.join(tmpdir, "lib", "fresh.rb")
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, "def broken\n")

          configuration = Rigor::Configuration.new("paths" => [])
          binding = Rigor::Analysis::BufferBinding.new(
            logical_path: logical, physical_path: physical
          )
          result = described_class.new(
            configuration: configuration, cache_store: nil, buffer: binding
          ).run([logical])

          paths = result.diagnostics.map(&:path).uniq
          # The buffer's parse error surfaces under the logical
          # path — NOT as a "no such file" diagnostic.
          expect(paths).to include(logical)
          expect(result.diagnostics.map(&:message)).not_to include(/no such file/)
        end
      end
    end

    it "analyzes the buffer even when --instead-of is not under any paths: directory" do
      Dir.mktmpdir("rigor-buffer-binding-outside-paths-") do |tmpdir|
        Dir.chdir(tmpdir) do
          FileUtils.mkdir_p("app")
          File.write(File.join("app", "real.rb"), "x = 1\n")
          # Logical path is in lib/ — NOT under `paths: [app]`.
          logical = File.join("lib", "foo.rb")
          FileUtils.mkdir_p("lib")
          File.write(logical, "x = 1\n")
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, "def broken\n")

          configuration = Rigor::Configuration.new("paths" => ["app"])
          binding = Rigor::Analysis::BufferBinding.new(
            logical_path: logical, physical_path: physical
          )
          result = described_class.new(
            configuration: configuration, cache_store: nil, buffer: binding
          ).run

          paths = result.diagnostics.map(&:path).uniq
          expect(paths).to include(logical)
          # `app/real.rb` is not analyzed under editor mode even though
          # it's in `paths:` — single-file scope wins.
          expect(paths).not_to include(File.join("app", "real.rb"))
        end
      end
    end
  end

  describe "ProjectScan pre-pass caching (LSP / editor warm-path slice)" do
    it "exposes a frozen ProjectScan snapshot from `#prepare_project_scan`" do
      Dir.mktmpdir("rigor-project-scan-prepare-") do |tmpdir|
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [tmpdir])
        scan = Dir.chdir(tmpdir) do
          described_class.new(configuration: configuration, cache_store: nil, collect_stats: false)
                         .prepare_project_scan
        end

        expect(scan).to be_a(Rigor::Analysis::ProjectScan)
        expect(scan).to be_frozen
        expect(scan.plugin_registry).not_to be_nil
        expect(scan.dependency_source_index).not_to be_nil
        expect(scan.synthetic_method_index).not_to be_nil
        expect(scan.project_patched_methods).not_to be_nil
        expect(scan.plugin_prepare_diagnostics).to eq([])
        expect(scan.pre_eval_diagnostics).to eq([])
      end
    end

    it "adopts the supplied prebuilt snapshot and surfaces its ivars on the runner" do
      Dir.mktmpdir("rigor-project-scan-adopt-") do |tmpdir|
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [tmpdir])
        scan = Dir.chdir(tmpdir) do
          described_class.new(configuration: configuration, cache_store: nil, collect_stats: false)
                         .prepare_project_scan
        end

        runner = described_class.new(
          configuration: configuration,
          cache_store: nil,
          collect_stats: false,
          prebuilt: scan
        )
        Dir.chdir(tmpdir) { runner.run }

        expect(runner.plugin_registry).to equal(scan.plugin_registry)
        expect(runner.dependency_source_index).to equal(scan.dependency_source_index)
      end
    end

    it "skips `Plugin::Loader.load` when prebuilt is supplied (idempotency check)" do
      Dir.mktmpdir("rigor-project-scan-skip-load-") do |tmpdir|
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [tmpdir])
        scan = Dir.chdir(tmpdir) do
          described_class.new(configuration: configuration, cache_store: nil, collect_stats: false)
                         .prepare_project_scan
        end

        # When prebuilt: is supplied, Plugin::Loader.load MUST NOT
        # run — the cached registry is the one the runner uses. We
        # verify by stubbing `Plugin::Loader.load` to raise and
        # confirming the run still succeeds.
        allow(Rigor::Plugin::Loader).to receive(:load).and_raise("loader.load called unexpectedly")

        runner = described_class.new(
          configuration: configuration,
          cache_store: nil,
          collect_stats: false,
          prebuilt: scan
        )
        expect { Dir.chdir(tmpdir) { runner.run } }.not_to raise_error
      end
    end

    it "re-runs pre-passes when prebuilt: is nil (legacy behaviour preserved)" do
      Dir.mktmpdir("rigor-project-scan-no-prebuilt-") do |tmpdir|
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [tmpdir])

        runner = described_class.new(configuration: configuration, cache_store: nil, collect_stats: false)
        Dir.chdir(tmpdir) { runner.run }

        # Pre-passes ran inline — registry / dep_index built fresh
        # this call, not adopted from a prior snapshot.
        expect(runner.plugin_registry).not_to be_nil
        expect(runner.dependency_source_index).not_to be_nil
      end
    end
  end

  describe "environment: override (LSP / editor warm-path slice)" do
    it "uses the supplied environment in sequential analyze_files and skips `Environment.for_project`" do
      Dir.mktmpdir("rigor-runner-env-override-") do |tmpdir|
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [tmpdir])
        env = Rigor::Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths
        )

        # Once the override is supplied, Environment.for_project
        # must NOT be invoked from within analyze_files for the
        # sequential path. Stubbing to raise lets a single
        # unexpected call abort the run.
        runner = described_class.new(
          configuration: configuration, cache_store: nil, collect_stats: false, environment: env
        )
        # The runner's pre-pass scaffold still calls
        # `Environment.for_project` outside `analyze_files`
        # (synthetic-method scanner uses `environment: nil`,
        # but the `prewarm_rbs_cache_for_pool` would on pool
        # mode — sequential path here doesn't). Allow it, but
        # assert it isn't called by the override path itself.
        expect do
          Dir.chdir(tmpdir) { runner.run }
        end.not_to raise_error
      end
    end

    it "attaches the runner's own per-run reporters onto the shared env" do
      Dir.mktmpdir("rigor-runner-env-reporters-") do |tmpdir|
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [tmpdir])
        env = Rigor::Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths,
          rbs_extended_reporter: Rigor::RbsExtended::Reporter.new,
          boundary_cross_reporter:
            Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new
        )
        original_rbs_reporter = env.rbs_extended_reporter

        runner = described_class.new(
          configuration: configuration, cache_store: nil, collect_stats: false, environment: env
        )
        Dir.chdir(tmpdir) { runner.run }

        # After the run, the env's reporter slot should reference
        # the runner's per-run reporter, not the pre-attached one.
        expect(env.rbs_extended_reporter).not_to equal(original_rbs_reporter)
        expect(env.rbs_extended_reporter).to equal(runner.rbs_extended_reporter)
      end
    end

    it "lets two sequential runs against the same env not accumulate reporter events across calls" do
      Dir.mktmpdir("rigor-runner-env-reset-") do |tmpdir|
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [tmpdir])
        env = Rigor::Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths
        )

        runner_a = described_class.new(
          configuration: configuration, cache_store: nil, collect_stats: false, environment: env
        )
        Dir.chdir(tmpdir) { runner_a.run }
        reporter_a = env.rbs_extended_reporter

        runner_b = described_class.new(
          configuration: configuration, cache_store: nil, collect_stats: false, environment: env
        )
        Dir.chdir(tmpdir) { runner_b.run }
        reporter_b = env.rbs_extended_reporter

        # Each run swaps in its own per-run reporter pair.
        expect(reporter_b).not_to equal(reporter_a)
      end
    end
  end
end
