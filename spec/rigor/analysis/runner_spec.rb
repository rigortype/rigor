# frozen_string_literal: true

require "rigor/analysis/runner"

# Path-error / parse-error specs intentionally bypass `analyze` because they exercise paths that do not exist or contain
# non-Ruby content; the helper assumes a writable tmpdir of `.rb` files. Everything else uses `analyze`.
RSpec.describe Rigor::Analysis::Runner do
  # T1 — a `rescue SyntaxError => e` in one file resolves to the project's `M::SyntaxError = Class.new(Error)` defined
  # in a sibling file (not core `::SyntaxError`), so a call on the rescued exception that the project class supports
  # does not fire undefined-method.
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
        result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
        offenders = result.diagnostics.select { |d| d.message.include?("line_number=") }
        expect(offenders).to be_empty
      end
    end
  end

  it "emits a diagnostic for a non-existent path instead of silently passing" do
    Dir.mktmpdir do |dir|
      missing = File.join(dir, "ghost.rb")
      configuration = Rigor::Configuration.new("paths" => [missing])
      # chdir into a clean tmpdir so the runner does not pick up rigor's own `Gemfile.lock` (which would fire the
      # O4-slice-3 missing-RBS diagnostic ahead of the file-not-found one).
      Dir.chdir(dir) do
        result = guarded_run(described_class.new(configuration: configuration))

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
        result = guarded_run(described_class.new(configuration: configuration))
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
      # See above: chdir away from rigor's repo root so the missing-RBS diagnostic doesn't surface ahead of the
      # path-error diagnostic.
      Dir.chdir(dir) do
        result = guarded_run(described_class.new(configuration: configuration))

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

  # Regression: Rails generator templates ship as `.rb` files but contain ERB interpolation (`<%= ... %>`), which Prism
  # cannot parse and the analyzer used to surface as up to ~20 noisy parse-error diagnostics per file. Redmine's
  # `lib/generators/redmine_plugin_model/templates/migration.rb` is the canonical example. The closing `%>` marker
  # cannot appear in valid Ruby (`%` is a binary operator that requires an operand on its right), so its presence is
  # sufficient evidence that the file is an ERB template; analysis silently skips it.
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
    # Each test plants a parse-error-shaped file (unclosed `def`) so analysis attempts surface as diagnostics; the test
    # then checks whether those diagnostics include the planted path.
    let(:bad_source) { "def broken\n" }

    it "skips the built-in vendor/bundle pattern when a directory expansion contains it" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src")
        vendored = File.join(src, "vendor", "bundle", "ruby", "4.0.0", "gems", "fakegem")
        FileUtils.mkdir_p(vendored)
        File.write(File.join(src, "real.rb"), bad_source)
        File.write(File.join(vendored, "lib.rb"), bad_source)

        configuration = Rigor::Configuration.new("paths" => [src])
        result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))

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
        result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))

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
        result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))

        expect(result.diagnostics.map(&:path)).to include(explicit)
      end
    end
  end

  describe "configuration wiring at runtime (audit guard)" do
    # Adjacent to the `target_ruby` block below, these specs guard against any of the documented `.rigor.yml` settings
    # going phantom — i.e., loaded into `Configuration` but never read at runtime. The `cache.path` regression that
    # prompted this block (the CLI hardcoded `".rigor/cache"` and ignored the config) is covered separately in
    # `cli_spec.rb`.

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
      # The `analyze` helper chdirs into a tmpdir; on macOS the tmpdir resolves under `/private/tmp/...`, so match by
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
      guarded_run(runner)

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
      result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
      diag = result.diagnostics.find { |d| d.rule == "dynamic.dependency-source.gem-not-found" }

      expect(diag).not_to be_nil
      expect(diag.path).to eq(".rigor.yml")
      expect(diag.message).to include("definitely-no-such-gem-rigor-12345")
      expect(diag.severity).to eq(:warning)
    end

    it "respects the per-receiver plugin veto (ADR-10 5a)" do
      # When a plugin declares manifest(owns_receivers: [...]) and the dispatcher's receiver IS owned by the plugin,
      # try_dependency_source must decline so the plugin contribution stays authoritative.
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
      guarded_run(runner)

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
      result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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

      result = guarded_run(runner)
      budget_diags = result.diagnostics.select { |d| d.rule == "dynamic.dependency-source.budget-exceeded" }

      expect(budget_diags.length).to eq(1)
      expect(budget_diags.first.path).to eq(".rigor.yml")
      expect(budget_diags.first.message).to include("prism")
      expect(budget_diags.first.message).to include("1250")
      expect(budget_diags.first.severity).to eq(:warning)
    end

    # Both coverage examples run on the process-wide shared store rather than `cache_store: nil`. They are alike in
    # every other run-cache key slot — empty path set, identical configuration — so they are exactly the pair that
    # used to collide, and the run-cache key's `bundler.lockfile` content slot (issue #564) is what separates them.
    # Keeping them on the shared store means a regression of that slot fails HERE too, not only in
    # `spec/rigor/cache/run_cache_lockfile_identity_spec.rb`.
    it "surfaces `rbs.coverage.missing-gem` :info exactly once when locked gems have no RBS (O4 slice 3)" do # rubocop:disable RSpec/ExampleLength
      # Build a tmpdir with Gemfile.lock listing two gems whose RBS is not covered by ANY of the four resolution paths
      # (DEFAULT_LIBRARIES / vendored / bundle / collection).
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
          runner = described_class.new(
            configuration: configuration, cache_store: RunnerHelpers.shared_cache_store
          )
          result = guarded_run(runner)
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
          runner = described_class.new(
            configuration: configuration, cache_store: RunnerHelpers.shared_cache_store
          )
          result = guarded_run(runner)
          coverage_diags = result.diagnostics.select { |d| d.rule == "rbs.coverage.missing-gem" }

          expect(coverage_diags).to be_empty
        end
      end
    end

    # ADR-93 WD3 — the standalone residual routing hint. `rbs_inline_library_resolvable?` is pinned false
    # suite-wide (spec_helper), which models the library-absent standalone install these examples describe.
    it "surfaces the WD3 :info hint when annotations exist but rbs-inline is absent" do
      Dir.mktmpdir("rigor-wd3-hint-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "lib"))
        File.write(File.join(tmpdir, "lib", "anno.rb"), <<~RUBY)
          # frozen_string_literal: true
          class Anno
            #: (Integer) -> void
            def log(n) = puts(n)
          end
        RUBY

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => ["lib"])
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
          hints = result.diagnostics.select { |d| d.rule == "rbs.coverage.inline-annotations-unsynthesized" }

          expect(hints.length).to eq(1)
          expect(hints.first.severity).to eq(:info)
          expect(hints.first.message).to include("lib/anno.rb")
          expect(hints.first.message).to include("rbs-inline")
        end
      end
    end

    it "does not surface the WD3 hint for RDoc directives alone (no real annotation)" do
      Dir.mktmpdir("rigor-wd3-nodoc-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "lib"))
        File.write(File.join(tmpdir, "lib", "plain.rb"), <<~RUBY)
          # frozen_string_literal: true
          class Plain #:nodoc:
            #:stopdoc:
            def work = 1
          end
        RUBY

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => ["lib"])
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
          hints = result.diagnostics.select { |d| d.rule == "rbs.coverage.inline-annotations-unsynthesized" }

          expect(hints).to be_empty
        end
      end
    end

    it "suppresses the WD3 hint when the rbs-inline library is resolvable", :rbs_inline_autowire do
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(true)
      Dir.mktmpdir("rigor-wd3-resolvable-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "lib"))
        File.write(File.join(tmpdir, "lib", "anno.rb"), "# @rbs return: Integer\ndef n = 1\n")

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => ["lib"])
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
          hints = result.diagnostics.select { |d| d.rule == "rbs.coverage.inline-annotations-unsynthesized" }

          expect(hints).to be_empty
        end
      end
    end

    # Regression: File.foreach / IO iteration blocks must get the same loop-body re-narrowing as Array#each,
    # so a local written in one `when` arm is visible in a sibling arm across iterations. Without it,
    # `flag` reads its pre-loop `false` at the `return true if flag` site, the guard folds to a constant, the
    # block-level `return` is dropped from the method's return summary, and the caller's guard on the method
    # false-fires `flow.always-truthy-condition` (polarity "falsey").
    it "does not false-fire always-falsey on a File.foreach block-carried local" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir("rigor-foreach-fixpoint-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "lib"))
        File.write(File.join(tmpdir, "lib", "scan.rb"), <<~RUBY)
          # frozen_string_literal: true
          class Scan
            def hit?(path)
              flag = false
              File.foreach(path) do |line|
                case line
                when /a/ then flag = true
                when /b/ then return true if flag
                end
              end
              false
            end

            def guard(path)
              return [] unless hit?(path)
              [1]
            end
          end
        RUBY

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => ["lib"])
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
          falsey = result.diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }

          expect(falsey).to be_empty
        end
      end
    end

    # ADR-72 — Gemfile.lock-gated bundled RBS overlays.
    def gemfile_lock_content(gem_name)
      <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            #{gem_name} (7.1.3)

        PLATFORMS
          ruby

        DEPENDENCIES
          #{gem_name}

        BUNDLED WITH
           2.5.6
      LOCK
    end

    def write_duration_project(tmpdir, lock_gem:)
      File.write(File.join(tmpdir, "Gemfile.lock"), gemfile_lock_content(lock_gem))
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
        result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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

    # Issue #632 — the overlay now names `ActiveSupport::Duration` too (its reader surface: `to_i`, …),
    # which is normally unsafe: `Duration` forwards anything its own class doesn't define to the wrapped
    # numeric via `method_missing`, so a partial declaration would turn every omitted member into a false
    # `call.undefined-method`. It stays safe here specifically because NO plugin is loaded in this test —
    # the numeric-multiplier chain (`3.minutes`) never reaches a `Duration` nominal in overlay-only mode
    # (that requires the plugin's `dynamic_return` rule, #534) — so the receiver here comes from the
    # project's OWN signature instead, the same way any third-party value with no in-repo `.rb` definition
    # would. `ActiveRecord::Relation`'s `open_receivers:` protection is a loaded PLUGIN's manifest entry,
    # which does not exist in this test at all; what protects `Widget.new.ttl.round` here is
    # `Rigor::Analysis::CheckRules::GEM_OVERLAY_OPEN_RECEIVERS`, GATED on the loaded RBS actually including
    # the `data/gem_overlay/activesupport/` directory (`CheckRules#gem_overlay_loaded?`) — which this test's
    # Gemfile.lock (below) makes true. The must-NOT-protect sibling right after this one locks NO gem at
    # all and shows the same class name getting NO exemption without that.
    def run_duration_reader_project(tmpdir)
      FileUtils.mkdir_p(File.join(tmpdir, "sig"))
      File.write(File.join(tmpdir, "Gemfile.lock"), gemfile_lock_content("activesupport"))
      File.write(File.join(tmpdir, "widget.rb"), "class Widget\nend\n")
      File.write(File.join(tmpdir, "sig", "widget.rbs"), <<~RBS)
        class Widget
          def ttl: () -> ActiveSupport::Duration
        end
      RBS
      File.write(File.join(tmpdir, "code.rb"), <<~RUBY)
        Rigor.dump_type(Widget.new.ttl.to_i)
        Widget.new.ttl.round
      RUBY

      Dir.chdir(tmpdir) do
        configuration = Rigor::Configuration.new(
          "paths" => [File.join(tmpdir, "widget.rb"), File.join(tmpdir, "code.rb")],
          "signature_paths" => [File.join(tmpdir, "sig")],
          "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
        )
        guarded_run(described_class.new(configuration: configuration, cache_store: nil)).diagnostics
      end
    end

    it "protects Duration's undeclared surface even with only the overlay loaded, no plugin at all" do
      Dir.mktmpdir("rigor-as-overlay-duration-") do |tmpdir|
        diagnostics = run_duration_reader_project(tmpdir)
        undefined = diagnostics.select { |d| d.rule == "call.undefined-method" }
        dumps = diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)

        # `to_i` is declared, so it resolves to Integer; `round` is not (real Duration API,
        # `method_missing`-forwarded to the wrapped numeric on the real class) and must not fire
        # `call.undefined-method` regardless.
        expect(dumps).to eq(["dump_type: Integer"])
        expect(undefined).to be_empty
      end
    end

    # The gating regression the review round caught: `GEM_OVERLAY_OPEN_RECEIVERS` naming a class is not
    # itself enough (ADR-26 WD1 — the protection must be active exactly when the RBS it protects is). A
    # project that never locks activesupport and happens to own a class of the exact same qualified name
    # gets ordinary `call.undefined-method` coverage on it, same as any other project class — the constant
    # must not leak protection to a project this bundle never reached.
    it "does NOT protect a project's own ActiveSupport::Duration when no gem overlay ever loaded" do
      Dir.mktmpdir("rigor-as-overlay-duration-unrelated-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "sig"))
        # No Gemfile.lock at all here — nothing makes any gem overlay (activesupport's included) eligible,
        # so `CheckRules#gem_overlay_loaded?` must read false for this run. The project happens to declare
        # its OWN class under the exact qualified name `ActiveSupport::Duration` — coincidence, not a
        # dependency on the gem — the same way `sig/`-augmented project classes work anywhere else.
        File.write(File.join(tmpdir, "sig", "duration.rbs"), <<~RBS)
          module ActiveSupport
            class Duration
              def foo: () -> Integer
            end
          end
        RBS
        File.write(File.join(tmpdir, "code.rb"), "ActiveSupport::Duration.new.bar\n")

        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new(
            "paths" => [File.join(tmpdir, "code.rb")],
            "signature_paths" => [File.join(tmpdir, "sig")]
          )
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
          undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }

          expect(undefined.map(&:method_name)).to eq(["bar"])
        end
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
          diags = result.diagnostics.select { |d| d.rule == "rbs.coverage.synthesized-namespace" }

          expect(diags).to be_empty
        end
      end
    end

    it "does not emit `call.undefined-method` on a value of a synthesized stub type" do
      Dir.mktmpdir("rigor-stub-no-fp-") do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, "sig"))
        # `Acme::Widget#remote` references `Net::FakeService`, which no loaded signature declares — Rigor stubs it so
        # Widget builds.
        File.write(File.join(tmpdir, "sig", "widget.rbs"), <<~RBS)
          class Acme::Widget
            def remote: () -> Net::FakeService
          end
        RBS
        # The call against the stub-typed value must NOT mis-fire undefined-method (the real Net::FakeService might
        # define it).
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
          undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }

          expect(undefined).to be_empty
        end
      end
    end

    describe "attr_* accessors suppress cross-file undefined-method" do
      # A class that defines `attr_reader :x` AND ships RBS that omits `x` (an incomplete `sig/`) must not fire a false
      # `undefined-method` on `obj.x` from another file. attr-declared accessors are recorded as discovered methods and
      # propagated project-wide.
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
          # `Widget.new` types the receiver as Widget (RBS-known), so the undefined-method rule actually evaluates
          # `size`.
          File.write(File.join(tmpdir, "user.rb"), <<~RUBY)
            w = Widget.new
            w.size
          RUBY
          Dir.chdir(tmpdir) do
            configuration = Rigor::Configuration.new(
              "paths" => [tmpdir], "signature_paths" => [File.join(tmpdir, "sig")]
            )
            result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
            result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
            result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
            result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
            result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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

      # Regression: the dispatcher's `try_project_patched_method` tier resolved the call's TYPE through the registry,
      # but `CheckRules#undefined_method_diagnostic` ran an independent "does this method exist?" probe that ignored the
      # registry — so a patched method on a concretely-typed receiver (`Nominal[String]` / `Constant["hello"]`) would
      # type correctly yet still fire `call.undefined-method`. The fix consults the registry in CheckRules at the same
      # precedence the dispatcher does.
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
            result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
            result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
            warns = result.diagnostics.select { |d| d.rule == "pre-eval.parse-error" }

            expect(warns.size).to eq(1)
            expect(warns.first.severity).to eq(:warning)
          end
        end
      end
    end

    # ADR-17 — when a project patch is NOT registered via `pre_eval:`, the call still fires `call.undefined-method`, but
    # the diagnostic names the proven definition site and carries it as the structured `project_definition_site` field
    # for `rigor triage` to key on.
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
            result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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

  describe "ADR-57 WD3 — cross-file module-singleton resolution" do
    it "resolves a `class << self` call on a module constant declared in a sibling file" do # rubocop:disable RSpec/ExampleLength
      Dir.mktmpdir("rigor-adr57-wd3-") do |tmpdir|
        File.write(File.join(tmpdir, "feature.rb"), <<~RUBY)
          module Feature
            class << self
              def label
                "flag"
              end
            end
          end
        RUBY
        File.write(File.join(tmpdir, "caller.rb"), <<~RUBY)
          require "rigor/testing"
          include Rigor::Testing

          assert_type("singleton(Feature)", Feature)
          assert_type(""flag"", Feature.label)
        RUBY
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [tmpdir])
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
          mismatches = result.diagnostics.select { |d| d.message.start_with?("assert_type ") }

          expect(mismatches).to(
            be_empty,
            "expected `Feature` to seed cross-file as `singleton(Feature)`; got: " \
            "#{mismatches.map(&:message).inspect}"
          )
        end
      end
    end
  end

  describe "union-arm predicate polarity narrowing" do
    # An ActiveSupport-shaped signature: `present?` / `blank?` are declared on Object, and NilClass
    # overrides them with the literal answers the narrowing reads.
    def write_presence_signature(tmpdir)
      FileUtils.mkdir_p(File.join(tmpdir, "sig"))
      File.write(File.join(tmpdir, "sig", "presence.rbs"), <<~RBS)
        class Object
          def present?: () -> bool
          def blank?: () -> bool
        end

        class NilClass
          def present?: () -> false
          def blank?: () -> true
        end
      RBS
    end

    def run_with_signature(source)
      Dir.mktmpdir("rigor-union-polarity-") do |tmpdir|
        write_presence_signature(tmpdir)
        File.write(File.join(tmpdir, "main.rb"), source)
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new(
            "paths" => [File.join(tmpdir, "main.rb")],
            "signature_paths" => [File.join(tmpdir, "sig")]
          )
          yield guarded_run(described_class.new(configuration: configuration, cache_store: nil))
        end
      end
    end

    it "drops the nil arm on the truthy edge of a predicate declared `() -> false` for nil" do
      run_with_signature(<<~RUBY) do |result|
        def probe(raw)
          login = raw.nil? ? nil : "x"
          login.downcase if login.present?
        end
      RUBY
        expect(result.diagnostics.map(&:rule)).not_to include("call.possible-nil-receiver")
      end
    end

    it "drops the nil arm on the falsey edge of a predicate declared `() -> true` for nil" do
      run_with_signature(<<~RUBY) do |result|
        def probe(raw)
          login = raw.nil? ? nil : "x"
          return if login.blank?

          login.downcase
        end
      RUBY
        expect(result.diagnostics.map(&:rule)).not_to include("call.possible-nil-receiver")
      end
    end

    # `login&.blank?` yields `nil` (falsey) for a nil receiver rather than NilClass#blank?'s declared
    # `true`, so the falsey edge admits nil and `login.downcase` really can raise.
    it "keeps the nil arm through a safe-navigation predicate" do
      run_with_signature(<<~RUBY) do |result|
        def probe(raw)
          login = raw.nil? ? nil : "x"
          login.downcase unless login&.blank?
        end
      RUBY
        expect(result.diagnostics.map(&:rule)).to include("call.possible-nil-receiver")
      end
    end
  end

  # The possible-nil rule asks "is the method present on every non-nil arm?" before witnessing, and a nameless arm
  # (Dynamic / Top / Bot) answers "present" permissively. A union whose non-nil arms are ALL nameless therefore
  # satisfied that gate vacuously and fired for every method name — including names defined on no class anywhere —
  # while a `String | nil` receiver calling a nonexistent method stayed silent. The decline and the must-still-fire
  # case are paired here deliberately: a decline-only spec would also pass if the rule stopped firing entirely.
  describe "possible-nil requires a nameable non-nil arm" do
    def nil_receiver_diags(result)
      result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
    end

    it "declines on a `Dynamic | nil` receiver calling a method that exists nowhere" do
      result = analyze(<<~RUBY)
        class Consumer
          def probe(store, cond)
            v = cond ? store.instance_variable_get(:@data) : nil
            v.frobnicate_xyz
          end
        end
      RUBY
      expect(nil_receiver_diags(result)).to be_empty
    end

    it "declines on a `Dynamic | nil` receiver even for a real method name" do
      result = analyze(<<~RUBY)
        class Consumer
          def probe(store, cond)
            v = cond ? store.instance_variable_get(:@data) : nil
            v.upcase
          end
        end
      RUBY
      expect(nil_receiver_diags(result)).to be_empty
    end

    it "still fires on a `String | nil` receiver calling a real String method" do
      result = analyze(<<~RUBY)
        class Consumer
          def probe(cond)
            v = cond ? "hello" : nil
            v.upcase
          end
        end
      RUBY
      expect(nil_receiver_diags(result)).not_to be_empty
    end

    it "still fires when one arm is nameable and another is Dynamic" do
      result = analyze(<<~RUBY)
        class Consumer
          def probe(store, cond)
            v = if cond == 1
                  store.instance_variable_get(:@data)
                elsif cond == 2
                  "hello"
                end
            v.upcase
          end
        end
      RUBY
      expect(nil_receiver_diags(result)).not_to be_empty
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
          expect(result.diagnostics.select { |d| d.rule == "call.unresolved-toplevel" }).to be_empty
        end
      end
    end

    it "escalates to :error under severity_profile: strict" do
      Dir.mktmpdir("rigor-adr34-strict-") do |tmpdir|
        main = write_main(tmpdir, "foo 1\n")
        Dir.chdir(tmpdir) do
          configuration = Rigor::Configuration.new("paths" => [main], "severity_profile" => "strict")
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
          result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
      # `3.0` matches the format regex but Prism rejects it. The one-time smoke parse in `Runner#run` converts the
      # `ArgumentError` into a single `:builtin configuration-error` diagnostic so the run fails fast rather than
      # crashing.
      result = analyze("x = 1\n", config: { "target_ruby" => "3.0" })
      diag = result.diagnostics.find { |d| d.rule == "configuration-error" }
      expect(diag).not_to be_nil
      expect(diag.path).to eq(".rigor.yml")
      expect(diag.message).to include('"3.0"')
      # The message must name the supported floor and where to read the right value, so the fix is obvious without a
      # guess-and-retry loop.
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

  # Issue #135 self-mutation sweep — the giant >300 LOC engine-file tier. `collect_symbol_fingerprints`
  # (private) folds one def-source/def-node table pair into the ADR-46 slice-4 fingerprint map; on the
  # ADR-85 WD3 incremental warm path an unchanged file's entry is a {Inference::DefHandle} carrying the
  # fingerprint captured when its seed bundle was built, so the fold reads `node.fingerprint` straight off the
  # handle instead of re-parsing and re-hashing the source slice. No existing spec ever populated the
  # discovery tables with a DefHandle (every other `symbol_fingerprints` exercise — `runner_lazy_prepass_spec`
  # — runs on freshly-parsed live `Prism::DefNode`s), so the DefHandle branch was unprotected. Unit-tested via
  # `.send` on the private fold rather than driving the whole incremental snapshot round-trip, matching this
  # file's own "cache_store surface" tests just above.
  describe "#collect_symbol_fingerprints (private, ADR-85 WD3 DefHandle path)" do
    it "reads a DefHandle's own precomputed fingerprint rather than re-hashing a (non-existent) live node" do
      runner = described_class.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
      handle = Rigor::Inference::DefHandle.new(path: "lib/x.rb", node_id: 1, name: "foo",
                                               fingerprint: "deadbeef", nesting: ["Foo"])
      sources = { "Foo" => { foo: "lib/x.rb:3" } }
      nodes = { "Foo" => { foo: handle } }
      result = Hash.new { |h, k| h[k] = {} }

      runner.send(:collect_symbol_fingerprints, result, sources, nodes, "#")

      expect(result["lib/x.rb"]).to eq({ "Foo#foo" => "deadbeef" })
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

    it "infers through a complex param shape while still preferring the local def over RBS dispatch" do
      # `def select(class_name, method_name, kind: :instance)` has a kwarg. The first-iteration binder
      # rejected the whole signature and answered `Dynamic[Top]`; the #524 per-parameter binder infers the
      # return — and the property this spec has always guarded still holds: the LOCAL def wins over
      # `Array#select` / `Kernel#select`, so `mt` is the def's own return, never `Array[Elem]`.
      result = analyze(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        def select(class_name, method_name, kind: :instance)
          class_name
        end
        mt = select("Array", :first)
        assert_type("\\"Array\\"", mt)
      RUBY

      expect(result.diagnostics.select { |d| d.rule == "assert.type-mismatch" }).to be_empty
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

      # `String | 42` narrowed to `Integer` keeps only the integer-side carrier (Constant[42] survives because it is a
      # subtype of Integer); the String carrier is dropped.
      mismatch = result.diagnostics.find { |d| d.rule == "assert.type-mismatch" }
      expect(mismatch).to be_nil
    end

    it "leaves the scope unchanged when the matcher shape is unrecognised" do
      # `to be_truthy` is intentionally NOT modelled; the post-call type of `x` should remain `String | nil` and
      # `x.upcase` should still flag.
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
      # `BEGIN { ... }` is a Prism::PreExecutionNode the engine does not recognise — a stable explain-mode trigger.
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
      # `rand(100)` could be zero but the analyzer cannot prove it, so the rule stays silent.
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

    # `expect_plugin_crash:` is set by the ONE example below whose subject is the runner's
    # plugin-isolation envelope; every other caller keeps the full guard (issue #674).
    def run_with_plugin(plugin_class:, source: "x = 1\n", expect_plugin_crash: false)
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
        runner = described_class.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: requirer
        )
        guarded_run(runner, allow_plugin_crash: expect_plugin_crash)
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

      result = run_with_plugin(plugin_class: bomb_class, expect_plugin_crash: true)
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
        result = guarded_run(described_class.new(configuration: configuration, cache_store: nil))
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
        [runner, guarded_run(runner)]
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
      # The contribution is silently dropped — no diagnostic. The rest of the run continues. (Plugins that need to
      # surface their own errors should emit through diagnostics_for_file.)
      expect(runtime_errors).to be_empty
      expect(result).to be_a(Rigor::Analysis::Result)
    end
  end

  describe "Plugin-side post_return_facts wiring (T.bind / T.assert_type! priority slice 2)" do
    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    # Synthetic plugin: recognises any call named `narrow_self_to_string!` and contributes a post_return_fact narrowing
    # self to `Nominal[String]` from that call onwards.
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
        runner = described_class.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        )
        guarded_run(runner)
      end
    end

    it "applies a plugin-contributed post_return_fact(target_kind: :self) to the surrounding scope" do
      # Without the narrowing, `self.upcase` would emit `call.undefined-method` because the implicit-self type at top
      # level isn't `String`. The plugin narrows self to `Nominal[String]` after `narrow_self_to_string!`, so
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
        runner = described_class.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        )
        result = guarded_run(runner)
        expect(result.diagnostics.select { |d| d.source_family == "plugin.noop-narrower" }).to be_empty
      end
    end
  end

  describe "Plugin#prepare invocation (v0.1.1 / ADR-9 slice 3)" do
    before { Rigor::Plugin.unregister! }
    after { Rigor::Plugin.unregister! }

    # `expect_plugin_crash:` — see the twin helper in the plugin-diagnostic-emission group above.
    def run_with_plugin(plugin_class, expect_plugin_crash: false)
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
        runner = described_class.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        )
        guarded_run(runner, allow_plugin_crash: expect_plugin_crash)
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

      result = run_with_plugin(klass, expect_plugin_crash: true)
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

    it "declines a reversed `int<max, min>` payload as unresolved instead of crashing the file" do
      # `Type::IntegerRange` raises on `min > max`; before the builder declined the pair, that
      # `ArgumentError` surfaced as an `internal analyzer error` row and the file was not analyzed.
      result = analyze_reporter_demo("ReversedBoundsDemo", "int<10, 1>")
      diag = result.diagnostics.find { |d| d.rule == "dynamic.rbs-extended.unresolved" }

      expect(diag).not_to be_nil
      expect(diag.message).to include("int<10, 1>")
      expect(diag.path).to include("demo.rbs")
      expect(diag.line).to eq(2)
      crashes = result.diagnostics.select { |d| d.message.start_with?("internal analyzer error") }
      expect(crashes).to be_empty
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

      # `_Stream` is namespace-relative (only `Buffers::_Stream` exists), so resolution must find it under the class's
      # namespace — and then flag the missing `read`, rather than reporting the interface unresolved.
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

          # `pool_mode?` is private; assert via `send` since the contract change IS about that predicate.
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
    # Slice 2: when the runner is wired with `buffer:`, the logical path in `paths:` is parsed from the physical
    # buffer's bytes but every diagnostic reports the LOGICAL path. The on-disk version of the logical file is silently
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
          runner = described_class.new(
            configuration: configuration, cache_store: nil, buffer: binding
          )
          result = guarded_run(runner)

          # The parse error from the buffer surfaces under the LOGICAL path — that's what the editor highlights.
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
          # `other` would normally surface a parse error — but under editor mode it MUST NOT be analyzed.
          File.write(other, "def also_broken\n")
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, "x = 1\n")

          configuration = Rigor::Configuration.new("paths" => ["lib"])
          binding = Rigor::Analysis::BufferBinding.new(
            logical_path: logical, physical_path: physical
          )
          runner = described_class.new(
            configuration: configuration, cache_store: nil, buffer: binding
          )
          result = guarded_run(runner)

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
          # Logical path doesn't exist on disk — user is editing a brand-new file via LSP.
          logical = File.join(tmpdir, "lib", "fresh.rb")
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, "def broken\n")

          configuration = Rigor::Configuration.new("paths" => [])
          binding = Rigor::Analysis::BufferBinding.new(
            logical_path: logical, physical_path: physical
          )
          runner = described_class.new(
            configuration: configuration, cache_store: nil, buffer: binding
          )
          result = guarded_run(runner, [logical])

          paths = result.diagnostics.map(&:path).uniq
          # The buffer's parse error surfaces under the logical path — NOT as a "no such file" diagnostic.
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
          runner = described_class.new(
            configuration: configuration, cache_store: nil, buffer: binding
          )
          result = guarded_run(runner)

          paths = result.diagnostics.map(&:path).uniq
          expect(paths).to include(logical)
          # `app/real.rb` is not analyzed under editor mode even though it's in `paths:` — single-file scope wins.
          expect(paths).not_to include(File.join("app", "real.rb"))
        end
      end
    end

    # Issue #795 — `Runner#evaluate_return_types` (the ADR-89 WD2 return-type re-evaluation probe
    # `IncrementalSession` calls to decide whether a changed def's dependents can be skipped) is reached
    # with `@buffer` set whenever the caller session is itself in editor mode. Its setup used to resolve
    # `target_files(expansion)` as `source_files:`, which under `buffer:` narrows to the buffer's single
    # logical path (single-file scope, slice 5) — dropping every OTHER project file's plugin-synthesized
    # virtual RBS from the probe's environment. `single-file scope` is right for what gets PER-FILE
    # ANALYZED; it is wrong for what the probe's environment is BUILT over, which must match the full
    # project the same way the per-file analysis environment already does (#793).
    it "resolves the return-type probe's environment over the whole project, not the buffer's single path" do
      Dir.mktmpdir("rigor-buffer-return-probe-") do |tmpdir|
        Dir.chdir(tmpdir) do
          FileUtils.mkdir_p("lib")
          logical = File.join("lib", "foo.rb")
          other = File.join("lib", "bar.rb")
          File.write(logical, "class Foo\n  def self.value\n    1\n  end\nend\n")
          File.write(other, "class Bar\nend\n")
          physical = File.join(tmpdir, "buffer.rb")
          File.write(physical, File.read(logical))

          configuration = Rigor::Configuration.new("paths" => ["lib"])
          binding = Rigor::Analysis::BufferBinding.new(logical_path: logical, physical_path: physical)
          runner = described_class.new(configuration: configuration, cache_store: nil, buffer: binding)

          captured_source_files = nil
          allow(Rigor::Environment).to receive(:for_project).and_wrap_original do |original, **kwargs|
            captured_source_files = kwargs[:source_files]
            original.call(**kwargs)
          end

          # `evaluate_return_types_setup`, called directly with an empty `specs:` — the wrapping
          # `#evaluate_return_types` short-circuits on an empty list before running any setup at all, and
          # what this example pins is the setup's environment resolution, not a real spec's re-evaluation.
          runner.send(:evaluate_return_types_setup, nil, [])

          expect(captured_source_files).not_to be_nil
          expect(captured_source_files.sort).to eq([logical, other].sort)
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
        Dir.chdir(tmpdir) { guarded_run(runner) }

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

        # When prebuilt: is supplied, Plugin::Loader.load MUST NOT run — the cached registry is the one the runner uses.
        # We verify by stubbing `Plugin::Loader.load` to raise and confirming the run still succeeds.
        allow(Rigor::Plugin::Loader).to receive(:load).and_raise("loader.load called unexpectedly")

        runner = described_class.new(
          configuration: configuration,
          cache_store: nil,
          collect_stats: false,
          prebuilt: scan
        )
        expect { Dir.chdir(tmpdir) { guarded_run(runner) } }.not_to raise_error
      end
    end

    it "re-runs pre-passes when prebuilt: is nil (legacy behaviour preserved)" do
      Dir.mktmpdir("rigor-project-scan-no-prebuilt-") do |tmpdir|
        File.write(File.join(tmpdir, "code.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [tmpdir])

        runner = described_class.new(configuration: configuration, cache_store: nil, collect_stats: false)
        Dir.chdir(tmpdir) { guarded_run(runner) }

        # Pre-passes ran inline — registry / dep_index built fresh this call, not adopted from a prior snapshot.
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

        # Once the override is supplied, Environment.for_project must NOT be invoked from within analyze_files for the
        # sequential path. Stubbing to raise lets a single unexpected call abort the run.
        runner = described_class.new(
          configuration: configuration, cache_store: nil, collect_stats: false, environment: env
        )
        # The runner's pre-pass scaffold still calls `Environment.for_project` outside `analyze_files` (synthetic-method
        # scanner uses `environment: nil`, but the `prewarm_rbs_cache_for_pool` would on pool mode — sequential path
        # here doesn't). Allow it, but assert it isn't called by the override path itself.
        expect do
          Dir.chdir(tmpdir) { guarded_run(runner) }
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
        Dir.chdir(tmpdir) { guarded_run(runner) }

        # After the run, the env's reporter slot should reference the runner's per-run reporter, not the pre-attached
        # one.
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
        Dir.chdir(tmpdir) { guarded_run(runner_a) }
        reporter_a = env.rbs_extended_reporter

        runner_b = described_class.new(
          configuration: configuration, cache_store: nil, collect_stats: false, environment: env
        )
        Dir.chdir(tmpdir) { guarded_run(runner_b) }
        reporter_b = env.rbs_extended_reporter

        # Each run swaps in its own per-run reporter pair.
        expect(reporter_b).not_to equal(reporter_a)
      end
    end

    it "deduplicates watched globs across producers in the run dependency descriptor" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "code.rb"), "x = 1\n")
        configuration = Rigor::Configuration.new("paths" => [dir])
        runner = described_class.new(configuration: configuration, cache_store: nil)
        expansion = runner.send(:expand_paths, configuration.paths)
        rbs_descriptor = Rigor::Cache::Descriptor.new(files: [], globs: [])

        plugin_class = Class.new(Rigor::Plugin::Base) do
          producer :p1, watch: -> { [["lib", "**/*.rb"]] } do
            1
          end
          producer :p2, watch: -> { [["lib", "**/*.rb"]] } do
            2
          end
        end
        plugin = plugin_class.allocate

        registry = Rigor::Plugin::Registry.new(plugins: [plugin])
        runner.instance_variable_set(:@plugin_registry, registry)

        desc = runner.send(:build_run_dependency_descriptor, expansion, rbs_descriptor)
        matching_globs = desc.globs.select { |g| g.pattern == "**/*.rb" && g.root.end_with?("/lib") }
        expect(matching_globs.size).to eq(1)
      end
    end
  end
end
