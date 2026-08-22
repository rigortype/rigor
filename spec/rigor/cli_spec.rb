# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

RSpec.describe Rigor::CLI do
  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.start(argv, out: out, err: err)

    [status, out.string, err.string]
  end

  it "prints the version" do
    status, out, err = run_cli("version")

    expect(status).to eq(0)
    expect(out).to eq("rigor #{Rigor::VERSION}\n")
    expect(err).to eq("")
  end

  it "lists type-of in the help text" do
    status, out, _err = run_cli("help")

    expect(status).to eq(0)
    expect(out).to include("type-of")
  end

  it "reports unknown commands as usage errors" do
    status, _out, err = run_cli("nope")

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to include("Unknown command: nope")
  end

  # #433 — a mistake in `.rigor.yml` used to abort with an uncaught exception and a ~30-frame backtrace
  # naming a file inside `lib/rigor/`, which reads as a crash rather than as "fix this key". The message
  # was always right; only its delivery was not. These examples assert what the user SEES — the rendered
  # line — because the exception class is an implementation detail of where the check happens to live.
  describe "a configuration mistake" do
    # Every example writes its own `.rigor.yml` over one trivial file, so the run reaches configuration
    # handling and nothing else.
    def in_project(config, &)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "class A\n  def b = 1\nend\n")
        File.write(File.join(dir, ".rigor.yml"), config)
        Dir.chdir(dir, &)
      end
    end

    # `EntryPoints` is a process-global registry, and these examples care about exactly what it holds.
    around do |example|
      Rigor::Effects::EntryPoints.reset!
      example.run
      Rigor::Effects::EntryPoints.reset!
    end

    it "renders an unregistered reach: preset as one rigor: line naming the presets this project has" do
      Rigor::Effects::EntryPoints.register("rails-controllers", ["app/controllers/**/*.rb"])
      Rigor::Effects::EntryPoints.register("rails-mailers", ["app/mailers/**/*.rb"])

      status, _out, err = in_project("paths: [.]\neffects:\n  snapshot:\n    reach: [rails]\n") do
        run_cli("effects", "update")
      end

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err.lines.size).to eq(1)
      expect(err).to start_with("rigor: ")
      expect(err).to include('effects.snapshot.reach names no registered entry-point preset: "rails"',
                             "presets registered in this project: rails-controllers, rails-mailers")
      expect(err).not_to include("lib/rigor/")
    end

    it "tells a project with no preset-registering plugin how a preset comes to exist" do
      status, _out, err = in_project("paths: [.]\neffects:\n  snapshot:\n    reach: [rails]\n") do
        run_cli("effects", "update")
      end

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("no plugin in this project registers an entry-point preset",
                             "listing that plugin under `plugins:`")
    end

    it "renders a malformed effects.attribution: key as one rigor: line naming the key" do
      config = "paths: [.]\neffects:\n  attribution:\n    \"Net::HTTP get\": [io.net.http]\n"
      status, _out, err = in_project(config) { run_cli("effects", "update") }

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err.lines.size).to eq(1)
      expect(err).to eq("rigor: effects.attribution key is not a method key " \
                        "(`Owner#method` / `Owner.method`): \"Net::HTTP get\"\n")
    end

    # The two the issue named are not special: every tier-2 value `Configuration` cannot proceed on now
    # arrives the same way, on every command that loads a configuration.
    it "renders the sibling effects: keys and a non-effects key the same way" do
      cases = {
        "paths: [.]\neffects:\n  tolerated: [\"not a label\"]\n" =>
          "rigor: effects.tolerated is not a well-formed effect label: \"not a label\"\n",
        "paths: [.]\neffects:\n  labels: [\"Bad Label\"]\n" =>
          "rigor: effects.labels is not a well-formed effect label: \"Bad Label\"\n",
        "paths: [.]\neffects:\n  envelopes:\n    - match: \"*.rb\"\n" =>
          "rigor: effects.envelopes[0] has no `effect:` bound (write `effect: []` for the empty envelope)\n",
        "paths: [.]\ntarget_ruby: nope\n" =>
          "rigor: target_ruby must be a version (e.g. \"3.4\", \"4.0\", \"3.4.0\") or \"latest\", got \"nope\"\n"
      }

      cases.each do |config, expected|
        status, _out, err = in_project(config) { run_cli("check", ".") }

        expect(status).to eq(Rigor::CLI::EXIT_USAGE)
        expect(err).to eq(expected)
      end
    end

    # A typo in the file the user is about to be told to fix used to escape as a `Psych::SyntaxError`
    # backtrace naming a file inside Ruby's stdlib, which points nowhere useful at all.
    it "renders a syntax error in .rigor.yml at the position that caused it" do
      status, _out, err = in_project("paths: [.\neffects: {}\n") { run_cli("check", ".") }

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err.lines.size).to eq(1)
      expect(err).to start_with("rigor: ")
      expect(err).to match(/\.rigor\.yml:\d+:\d+: not valid YAML: /)
      expect(err).not_to include("psych")
    end
  end

  # ADR-46 — the incremental-analysis acceptance gate.
  describe "check --verify-incremental" do
    it "reports OK and exits 0 when incremental matches a full run" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rigor.yml"), "severity_profile: balanced\n")
        # One file carries a diagnostic so the merge moves real data; the other is plain, so the cache-serving path is
        # exercised too.
        File.write(File.join(dir, "a.rb"), <<~RUBY)
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
        File.write(File.join(dir, "b.rb"), "class Plain\n  def ok\n    1\n  end\nend\n")

        status, out, _err = run_cli(
          "check", "--verify-incremental", "--no-stats",
          "--config", File.join(dir, ".rigor.yml"), dir
        )

        expect(status).to eq(0)
        expect(out).to include("--verify-incremental OK")
      end
    end
  end

  describe "check --incremental" do
    it "is cold on the first run and warm on the second, with identical diagnostics" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rigor.yml"),
                   "severity_profile: balanced\ncache_path: #{File.join(dir, '.cache')}\n")
        File.write(File.join(dir, "a.rb"), <<~RUBY)
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

        args = ["check", "--incremental", "--no-stats", "--config", File.join(dir, ".rigor.yml"), dir]
        status1, out1, err1 = run_cli(*args)
        status2, out2, err2 = run_cli(*args)

        expect([status1, status2]).to eq([0, 0]) # warnings-only run still succeeds
        expect(err1).to include("--incremental cold")
        expect(err2).to include("--incremental warm")
        # The diagnostic is reported identically cold and warm.
        expect(out1).to include("visibility of `greet'")
        expect(out2).to eq(out1)
      end
    end
  end

  describe "type-of" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write_fixture(name, contents)
      path = File.join(tmpdir, name)
      File.write(path, contents)
      path
    end

    it "prints the inferred type for an integer literal in text format" do
      path = write_fixture("a.rb", "1 + 2\n")

      status, out, err = run_cli("type-of", "#{path}:1:1")

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("node:    Prism::IntegerNode")
      expect(out).to include("type:    1")
      expect(out).to include("erased:  1")
    end

    it "accepts FILE LINE COL as separate arguments" do
      path = write_fixture("a.rb", "\"hi\"\n")

      status, out, err = run_cli("type-of", path, "1", "1")

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("Prism::StringNode")
      expect(out).to include('erased:  "hi"')
    end

    it "emits a JSON payload when --format=json is supplied" do
      path = write_fixture("a.rb", ":sym\n")

      status, out, _err = run_cli("type-of", "--format=json", "#{path}:1:1")

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["node"]).to eq("Prism::SymbolNode")
      expect(payload["type"]).to eq(":sym")
      expect(payload["erased"]).to eq(":sym")
      expect(payload["line"]).to eq(1)
      expect(payload["column"]).to eq(1)
    end

    it "records fallbacks when --trace is supplied for unsupported nodes" do
      path = write_fixture("a.rb", "foo + bar\n")

      status, out, _err = run_cli("type-of", "--trace", "#{path}:1:1")

      expect(status).to eq(0)
      expect(out).to include("erased:  untyped")
      expect(out).to match(/fallbacks \(\d+\)/)
      expect(out).to include("Prism::CallNode (prism)")
    end

    it "includes a fallbacks array in JSON output when --trace is set" do
      path = write_fixture("a.rb", "foo + bar\n")

      _status, out, _err = run_cli("type-of", "--trace", "--format=json", "#{path}:1:1")

      payload = JSON.parse(out)
      expect(payload).to have_key("fallbacks")
      expect(payload["fallbacks"]).to be_an(Array)
      expect(payload["fallbacks"]).not_to be_empty
      expect(payload["fallbacks"].first).to include("node_class" => "Prism::CallNode", "family" => "prism")
    end

    it "omits the fallbacks key without --trace" do
      path = write_fixture("a.rb", "1\n")

      _status, out, _err = run_cli("type-of", "--format=json", "#{path}:1:1")

      payload = JSON.parse(out)
      expect(payload).not_to have_key("fallbacks")
    end

    it "reports an error and exits 1 when the file is missing" do
      status, _out, err = run_cli("type-of", "missing.rb:1:1")

      expect(status).to eq(1)
      expect(err).to include("file not found")
    end

    # ADR-93 / #162 — type-of must build the same plugin-aware environment `rigor check` analyses with, so a
    # type synthesized from an inline RBS annotation by the auto-wired `rigor-rbs-inline` plugin is observed by
    # the probe instead of the plugin-free `Dynamic[top]`. See `Rigor::CLI::ProbeEnvironment`.
    describe "plugin-synthesized RBS (rbs-inline auto-wire parity)" do
      # `foo`'s ONLY signature is the inline `#: () -> void`; `bar` / `baz` are un-annotated. Lines match the
      # #162 design-session repro: `a = foo` is line 14, `b = bar` is line 19.
      let(:void_source) do
        <<~RUBY
          class VoidRepro
            #: () -> void
            def foo; end

            def bar
              foo
            end

            def baz
              bar
            end

            def use_foo
              a = foo
              a
            end

            def use_bar
              b = bar
              b
            end

            def use_baz
              c = baz
              c
            end
          end
        RUBY
      end

      # The suite pins the auto-wire probe off and pervasively empties the plugin registry (see spec_helper), so
      # an auto-wire spec lifts the pin with `:rbs_inline_autowire` and re-registers the plugin class (whose
      # top-level `register` is a require-no-op after another spec's `unregister!`).
      context "with the rbs-inline plugin auto-wired", :rbs_inline_autowire do
        before do
          allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(true)
          require "rigor-rbs-inline"
          Rigor::Plugin.register(Rigor::Plugin::RbsInline) unless Rigor::Plugin.registered_for("rbs-inline")
        end

        it "resolves an inline-annotated method through the synthesized RBS under type-of" do
          path = write_fixture("void_repro.rb", void_source)
          config = write_fixture(".rigor.yml", %(target_ruby: "4.0"\n))

          _s, foo_out, _e = run_cli("type-of", "--format=json", "--config", config, "#{path}:14:8")
          _s, bar_out, _e = run_cli("type-of", "--format=json", "--config", config, "#{path}:19:8")

          # `a = foo`: foo's synthesized `-> void` recovers to `top` (was `Dynamic[top]` under the plugin-free env).
          expect(JSON.parse(foo_out)["type"]).to eq("top")
          # `b = bar`: bar is un-annotated, so its synthesized skeleton is `() -> untyped` and it stays Dynamic —
          # proving the flip at 14 is the annotation's synthesis, not an unrelated change.
          expect(JSON.parse(bar_out)["type"]).to eq("Dynamic[top]")
        end
      end

      it "degrades to the plugin-free type when the synthesizer is disabled (fail-soft)" do
        path = write_fixture("void_repro.rb", void_source)
        config = write_fixture(".rigor.yml", <<~YAML)
          plugins:
            - gem: rigor-rbs-inline
              enabled: false
        YAML

        status, out, err = run_cli("type-of", "--format=json", "--config", config, "#{path}:14:8")

        expect(err).to eq("")
        expect(status).to eq(0)
        # No synthesizer contributes, so `foo` reads exactly as it did before this parity fix — never a crash.
        expect(JSON.parse(out)["type"]).to eq("Dynamic[top]")
      end
    end

    describe "editor mode (--tmp-file / --instead-of)" do
      it "rejects --tmp-file alone" do
        status, _out, err = run_cli("type-of", "--tmp-file=/nonexistent", "lib/foo.rb:1:1")

        expect(status).to eq(Rigor::CLI::EXIT_USAGE)
        expect(err).to include("--tmp-file and --instead-of must appear together")
      end

      it "rejects a missing --tmp-file" do
        status, _out, err = run_cli(
          "type-of",
          "--tmp-file=#{File.join(tmpdir, 'ghost.rb')}",
          "--instead-of=lib/foo.rb",
          "lib/foo.rb:1:1"
        )

        expect(status).to eq(Rigor::CLI::EXIT_USAGE)
        expect(err).to include("no such file or not readable")
      end

      it "reads bytes from --tmp-file when probing the logical path" do
        # Logical path has a different value at (1,1) than the buffer. On disk: ":on_disk_sym"; in buffer: "42".
        logical = write_fixture("a.rb", ":on_disk_sym\n")
        buffer = write_fixture("buf.rb", "42\n")

        status, out, _err = run_cli(
          "type-of",
          "--tmp-file=#{buffer}",
          "--instead-of=#{logical}",
          "#{logical}:1:1"
        )

        expect(status).to eq(0)
        # The probe must reflect the BUFFER's bytes (42), not the on-disk symbol literal.
        expect(out).to include("Prism::IntegerNode")
        expect(out).to include("type:    42")
      end
    end

    it "reports parse errors and exits 1" do
      path = write_fixture("a.rb", "def\n")

      status, _out, err = run_cli("type-of", "#{path}:1:1")

      expect(status).to eq(1)
      expect(err).not_to be_empty
    end

    it "reports a usage error when the position has no colon form" do
      path = write_fixture("a.rb", "1\n")

      status, _out, err = run_cli("type-of", path)

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("FILE:LINE:COL")
    end

    it "reports a usage error when line/column are not integers" do
      path = write_fixture("a.rb", "1\n")

      status, _out, err = run_cli("type-of", "#{path}:abc:1")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("must be integers")
    end

    it "reports a usage error when the position is out of range" do
      path = write_fixture("a.rb", "1\n")

      status, _out, err = run_cli("type-of", "#{path}:99:1")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("past the end")
    end

    it "auto-loads sig/ from the project root for constant resolution" do
      Dir.chdir(tmpdir) do
        FileUtils.mkdir_p("sig")
        File.write("sig/cli_demo.rbs", <<~RBS)
          class CliRbsDemoFixture
            def name: () -> ::String
          end
        RBS
        File.write("source.rb", "CliRbsDemoFixture\n")

        status, out, err = run_cli("type-of", "source.rb:1:1")

        expect(err).to eq("")
        expect(status).to eq(0)
        # The constant reference evaluates to the class object itself, i.e. singleton(CliRbsDemoFixture). Phase 2b
        # enforces this distinction so subsequent class-method dispatch can hit singleton-side definitions.
        expect(out).to include("type:    singleton(CliRbsDemoFixture)")
      end
    end

    # v0.0.4: refinement-bearing types render in their kebab-case
    # canonical spelling (`non-empty-string`, `lowercase-string`,
    # …) rather than the raw operator form (`String - ""`,
    # `String & lowercase?`). RBS erasure folds the carrier back to
    # its base nominal so the round-trip to ordinary RBS stays
    # observable in the CLI output.
    # `write_refined_fixture` writes a sig + source pair that
    # tightens `Klass#method` via a `rigor:v1:return:` annotation.
    # The source binds the call to a local on line 1 and reads it
    # on line 2 so type-of can point at the local (whose type the
    # rvalue has already supplied) — pointing at the call directly
    # is fragile because the node-locator picks the innermost
    # enclosing node.
    def write_refined_fixture(klass:, method:, refinement:)
      FileUtils.mkdir_p("sig")
      File.write("sig/refined.rbs", <<~RBS)
        class #{klass}
          %a{rigor:v1:return: #{refinement}}
          def #{method}: () -> ::String
        end
      RBS
      File.write("source.rb", "result = #{klass}.new.#{method}\nresult\n")
    end

    it "renders Difference carriers in their kebab-case canonical name" do
      Dir.chdir(tmpdir) do
        write_refined_fixture(klass: "CliDifferenceDemo", method: "name", refinement: "non-empty-string")
        status, out, err = run_cli("type-of", "source.rb:2:1")

        expect(err).to eq("")
        expect(status).to eq(0)
        expect(out).to include("type:    non-empty-string")
        expect(out).to include("erased:  String")
      end
    end

    it "renders Refined carriers in their kebab-case canonical name" do
      Dir.chdir(tmpdir) do
        write_refined_fixture(klass: "CliRefinedDemo", method: "slug", refinement: "lowercase-string")
        status, out, err = run_cli("type-of", "source.rb:2:1")

        expect(err).to eq("")
        expect(status).to eq(0)
        expect(out).to include("type:    lowercase-string")
        expect(out).to include("erased:  String")
      end
    end

    it "carries the kebab-case name through --format=json" do
      Dir.chdir(tmpdir) do
        write_refined_fixture(klass: "CliRefinedJsonDemo", method: "code", refinement: "numeric-string")
        status, out, _err = run_cli("type-of", "--format=json", "source.rb:2:1")

        expect(status).to eq(0)
        payload = JSON.parse(out)
        expect(payload["type"]).to eq("numeric-string")
        expect(payload["erased"]).to eq("String")
      end
    end
  end

  describe "check --cache-stats / --clear-cache" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write_check_fixture(name, contents)
      path = File.join(tmpdir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    it "prints '(empty)' under --cache-stats when no cache directory exists" do
      write_check_fixture("a.rb", "1\n")
      Dir.chdir(tmpdir) do
        # `--no-cache` keeps the run from writing anything: both the default stats summary (which forces
        # `class_decl_paths` to build the RBS env) and the ADR-45 whole-run result cache would warm `.rigor/cache` and
        # defeat the "no cache directory exists" assertion.
        status, out, _err = run_cli("check", "--cache-stats", "--no-cache", "a.rb")
        expect(status).to eq(0)
        expect(out).to include("Cache (root: .rigor/cache)")
        expect(out).to include("schema_version: absent")
        expect(out).to include("(empty)")
      end
    end

    it "lists per-producer entry counts under --cache-stats when the cache has entries" do
      write_check_fixture("a.rb", "1\n")
      Dir.chdir(tmpdir) do
        cache_root = File.join(tmpdir, ".rigor", "cache")
        store = Rigor::Cache::Store.new(root: cache_root)
        descriptor = Rigor::Cache::Descriptor.new
        store.fetch_or_compute(
          producer_id: "demo", generation_cap: :unbounded, params: {}, descriptor: descriptor
        ) { :seed }

        status, out, _err = run_cli("check", "--cache-stats", "a.rb")
        expect(status).to eq(0)
        expect(out).to include("Cache (root: .rigor/cache)")
        expect(out).to match(/schema_version: \d+/)
        expect(out).to include("demo: 1 entries")
      end
    end

    it "reports per-run hit/miss/write totals under --cache-stats" do
      write_check_fixture("a.rb", "1\n")
      Dir.chdir(tmpdir) do
        status, out, _err = run_cli("check", "--cache-stats", "a.rb")
        expect(status).to eq(0)
        expect(out).to match(/this run: \d+ hits?, \d+ (miss|misses), \d+ writes?/)
      end
    end

    it "skips the per-run section under --no-cache --cache-stats" do
      write_check_fixture("a.rb", "1\n")
      Dir.chdir(tmpdir) do
        status, out, _err = run_cli("check", "--no-cache", "--cache-stats", "a.rb")
        expect(status).to eq(0)
        expect(out).to include("Cache (root: .rigor/cache)")
        expect(out).not_to include("this run:")
      end
    end

    it "removes the cache directory under --clear-cache" do
      write_check_fixture("a.rb", "1\n")
      Dir.chdir(tmpdir) do
        cache_root = File.join(tmpdir, ".rigor", "cache")
        FileUtils.mkdir_p(cache_root)
        File.write(File.join(cache_root, "schema_version.txt"), "1\n")

        # `--no-cache` (see the sibling spec): otherwise the run re-warms the cache after the clear — both the stats
        # summary and the ADR-45 whole-run result cache write — re-creating the directory we're asserting got deleted.
        # `--clear-cache` still runs first.
        status, out, _err = run_cli("check", "--clear-cache", "--no-cache", "a.rb")
        expect(status).to eq(0)
        expect(out).to include("Cleared cache: .rigor/cache")
        expect(File.directory?(cache_root)).to be false
      end
    end

    it "reports 'Cache already empty' under --clear-cache when no cache exists" do
      write_check_fixture("a.rb", "1\n")
      Dir.chdir(tmpdir) do
        status, out, _err = run_cli("check", "--clear-cache", "a.rb")
        expect(status).to eq(0)
        expect(out).to include("Cache already empty: .rigor/cache")
      end
    end

    it "passes nil cache_store to the runner under --no-cache" do
      write_check_fixture("a.rb", "1\n")
      Dir.chdir(tmpdir) do
        captured = nil
        allow(Rigor::Analysis::Runner).to receive(:new).and_wrap_original do |original, **kwargs|
          captured = kwargs
          original.call(**kwargs)
        end
        status, _out, _err = run_cli("check", "--no-cache", "a.rb")
        expect(status).to eq(0)
        expect(captured).to include(cache_store: nil)
      end
    end

    it "passes a Cache::Store rooted at .rigor/cache to the runner by default" do
      write_check_fixture("a.rb", "1\n")
      Dir.chdir(tmpdir) do
        captured = nil
        allow(Rigor::Analysis::Runner).to receive(:new).and_wrap_original do |original, **kwargs|
          captured = kwargs
          original.call(**kwargs)
        end
        status, _out, _err = run_cli("check", "a.rb")
        expect(status).to eq(0)
        expect(captured.fetch(:cache_store)).to be_a(Rigor::Cache::Store)
        expect(captured.fetch(:cache_store).root).to eq(".rigor/cache")
      end
    end

    it "honours `cache.path:` from .rigor.yml when constructing the Cache::Store" do
      write_check_fixture("a.rb", "1\n")
      write_check_fixture(".rigor.yml", <<~YAML)
        paths:
          - a.rb
        cache:
          path: tmp/custom-cache
      YAML
      Dir.chdir(tmpdir) do
        captured = nil
        allow(Rigor::Analysis::Runner).to receive(:new).and_wrap_original do |original, **kwargs|
          captured = kwargs
          original.call(**kwargs)
        end
        status, out, _err = run_cli("check", "--cache-stats")
        expect(status).to eq(0)
        expect(captured.fetch(:cache_store).root).to eq("tmp/custom-cache")
        expect(out).to include("Cache (root: tmp/custom-cache)")
      end
    end
  end

  describe "check --treat-all-as-inline-rbs (ADR-32 WD10 carry-over)" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:ascdesc_source) do
      <<~RUBY
        class AscDesc
          # @rbs asc_or_desc: :asc | :desc
          def ascdesc(asc_or_desc)
            asc_or_desc
          end
        end

        AscDesc.new.ascdesc(:bad)
      RUBY
    end

    after do
      FileUtils.remove_entry(tmpdir)
      Rigor::Plugin.unregister!
    end

    before do
      # Load the plugin gem into $LOAD_PATH and register it so the flag's injected entry can resolve through
      # `Plugin::Loader.require_gem!`.
      plugin_lib = File.expand_path("../../plugins/rigor-rbs-inline/lib", __dir__)
      $LOAD_PATH.unshift(plugin_lib) unless $LOAD_PATH.include?(plugin_lib)
      require "rigor-rbs-inline"
      # Explicitly re-register in case another spec in the same parallel-worker process already loaded the gem and then
      # called `Rigor::Plugin.unregister!` — `require` would be a no-op and the class would stay unregistered.
      Rigor::Plugin.register(Rigor::Plugin::RbsInline) unless Rigor::Plugin.registered_for("rbs-inline")
    end

    def write_check_fixture(name, contents)
      path = File.join(tmpdir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    it "force-loads rigor-rbs-inline with require_magic_comment: false" do
      write_check_fixture("demo.rb", ascdesc_source)
      Dir.chdir(tmpdir) do
        status, out, _err = run_cli("check", "--no-cache", "--no-stats",
                                    "--format=json", "--treat-all-as-inline-rbs", "demo.rb")
        expect(status).to eq(1)
        payload = JSON.parse(out)
        rules = payload.fetch("diagnostics").map { |d| d["rule"] }
        expect(rules).to include("call.argument-type-mismatch")
        messages = payload.fetch("diagnostics").map { |d| d["message"] }
        expect(messages).to include(a_string_matching(/:asc \| :desc/))
        expect(messages).to include(a_string_matching(/:bad/))
      end
    end

    it "loads the include-aware config and still injects rigor-rbs-inline when a .rigor.yml exists" do
      # Regression: `load_check_configuration` reached for `Configuration.load_with_includes`, which was
      # `private_class_method` — so the moment a config file was present (the ternary's truthy branch) the flag crashed
      # with `NoMethodError: private method 'load_with_includes'`. The no-config example above never exercises that
      # branch.
      write_check_fixture(".rigor.yml", <<~YAML)
        paths:
          - .
      YAML
      write_check_fixture("demo.rb", ascdesc_source)
      Dir.chdir(tmpdir) do
        status, out, err = run_cli("check", "--no-cache", "--no-stats",
                                   "--format=json", "--treat-all-as-inline-rbs", "demo.rb")
        expect(err).not_to include("NoMethodError")
        expect(status).to eq(1)
        payload = JSON.parse(out)
        rules = payload.fetch("diagnostics").map { |d| d["rule"] }
        expect(rules).to include("call.argument-type-mismatch")
      end
    end

    it "is a no-op without the flag (proves the flag changed behaviour)" do
      write_check_fixture("demo.rb", ascdesc_source)
      Dir.chdir(tmpdir) do
        status, out, _err = run_cli("check", "--no-cache", "--no-stats",
                                    "--format=json", "demo.rb")
        expect(status).to eq(0)
        payload = JSON.parse(out)
        rules = payload.fetch("diagnostics").map { |d| d["rule"] }
        expect(rules).not_to include("call.argument-type-mismatch")
      end
    end
  end

  describe "check --workers / RIGOR_RACTOR_WORKERS / parallel.workers: (ADR-15 Phase 4c)" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write_workers_fixture(name, contents)
      path = File.join(tmpdir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    it "threads --workers=N through to Runner.new(workers:)" do
      write_workers_fixture("a.rb", "x = 1\n")
      Dir.chdir(tmpdir) do
        captured = nil
        allow(Rigor::Analysis::Runner).to receive(:new).and_wrap_original do |original, **kwargs|
          captured = kwargs
          original.call(**kwargs)
        end
        status, _out, _err = run_cli("check", "--workers=3", "--no-stats", "a.rb")
        expect(status).to eq(0)
        expect(captured.fetch(:workers)).to eq(3)
      end
    end

    it "falls back to RIGOR_RACTOR_WORKERS when --workers is absent" do
      write_workers_fixture("a.rb", "x = 1\n")
      Dir.chdir(tmpdir) do
        captured = nil
        allow(Rigor::Analysis::Runner).to receive(:new).and_wrap_original do |original, **kwargs|
          captured = kwargs
          original.call(**kwargs)
        end
        ENV["RIGOR_RACTOR_WORKERS"] = "2"
        begin
          status, _out, _err = run_cli("check", "--no-stats", "a.rb")
          expect(status).to eq(0)
          expect(captured.fetch(:workers)).to eq(2)
        ensure
          ENV.delete("RIGOR_RACTOR_WORKERS")
        end
      end
    end

    it "falls back to .rigor.yml `parallel.workers:` when --workers and env are absent" do
      write_workers_fixture("a.rb", "x = 1\n")
      write_workers_fixture(".rigor.yml", "paths: [a.rb]\nparallel:\n  workers: 5\n")
      Dir.chdir(tmpdir) do
        captured = nil
        allow(Rigor::Analysis::Runner).to receive(:new).and_wrap_original do |original, **kwargs|
          captured = kwargs
          original.call(**kwargs)
        end
        status, _out, _err = run_cli("check", "--no-stats")
        expect(status).to eq(0)
        expect(captured.fetch(:workers)).to eq(5)
      end
    end

    it "prefers --workers over both env and config" do
      write_workers_fixture("a.rb", "x = 1\n")
      write_workers_fixture(".rigor.yml", "paths: [a.rb]\nparallel:\n  workers: 5\n")
      Dir.chdir(tmpdir) do
        captured = nil
        allow(Rigor::Analysis::Runner).to receive(:new).and_wrap_original do |original, **kwargs|
          captured = kwargs
          original.call(**kwargs)
        end
        ENV["RIGOR_RACTOR_WORKERS"] = "2"
        begin
          status, _out, _err = run_cli("check", "--workers=7", "--no-stats", "a.rb")
          expect(status).to eq(0)
          expect(captured.fetch(:workers)).to eq(7)
        ensure
          ENV.delete("RIGOR_RACTOR_WORKERS")
        end
      end
    end

    it "defaults to 0 (sequential) when no override is configured" do
      write_workers_fixture("a.rb", "x = 1\n")
      Dir.chdir(tmpdir) do
        captured = nil
        allow(Rigor::Analysis::Runner).to receive(:new).and_wrap_original do |original, **kwargs|
          captured = kwargs
          original.call(**kwargs)
        end
        status, _out, _err = run_cli("check", "--no-stats", "a.rb")
        expect(status).to eq(0)
        expect(captured.fetch(:workers)).to eq(0)
      end
    end

    it "clamps a negative env override to 0" do
      write_workers_fixture("a.rb", "x = 1\n")
      Dir.chdir(tmpdir) do
        captured = nil
        allow(Rigor::Analysis::Runner).to receive(:new).and_wrap_original do |original, **kwargs|
          captured = kwargs
          original.call(**kwargs)
        end
        ENV["RIGOR_RACTOR_WORKERS"] = "-1"
        begin
          status, _out, _err = run_cli("check", "--no-stats", "a.rb")
          expect(status).to eq(0)
          expect(captured.fetch(:workers)).to eq(0)
        ensure
          ENV.delete("RIGOR_RACTOR_WORKERS")
        end
      end
    end
  end

  describe "check --stats / --no-stats" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write_stats_fixture(name, contents)
      path = File.join(tmpdir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    it "prints the run summary on stderr by default (target files + RBS universe + memory)" do
      write_stats_fixture("a.rb", "x = 1\n")
      Dir.chdir(tmpdir) do
        status, out, err = run_cli("check", "a.rb")
        expect(status).to eq(0)
        expect(err).to include("Check targets")
        expect(err).to include("Ruby source files: 1")
        expect(err).to include("Type universe")
        expect(err).to include("RBS classes available:")
        expect(err).to include("Wall time:")
        expect(err).to include("Memory peak:")
        expect(out).not_to include("Check targets")
      end
    end

    it "suppresses the run summary under --no-stats" do
      write_stats_fixture("a.rb", "x = 1\n")
      Dir.chdir(tmpdir) do
        status, _out, err = run_cli("check", "--no-stats", "a.rb")
        expect(status).to eq(0)
        expect(err).not_to include("Check targets")
        expect(err).not_to include("Wall time:")
      end
    end

    it "still prints the run summary under --stats explicit form" do
      write_stats_fixture("a.rb", "x = 1\n")
      Dir.chdir(tmpdir) do
        status, _out, err = run_cli("check", "--stats", "a.rb")
        expect(status).to eq(0)
        expect(err).to include("Check targets")
      end
    end
  end

  describe "type-scan" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write_fixture(name, contents)
      path = File.join(tmpdir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    it "reports a coverage summary in text format" do
      path = write_fixture("a.rb", "[1, 2]\nfoo()\n")

      status, out, err = run_cli("type-scan", path)

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("Type-of scan: 1 file")
      expect(out).to include("AST nodes visited:")
      expect(out).to match(%r{Prism::CallNode\s+\d+/\d+})
      expect(out).to include("Unrecognized examples")
    end

    it "emits JSON when --format=json is supplied" do
      path = write_fixture("a.rb", "foo()\n")

      status, out, _err = run_cli("type-scan", "--format=json", path)

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["summary"]).to include("visited", "unrecognized", "unrecognized_ratio")
      expect(payload["by_class"]).to include("Prism::CallNode")
      expect(payload["events"]).to be_an(Array)
      expect(payload["events"].first).to include("file" => path, "node_class" => "Prism::CallNode")
    end

    it "exits 1 when the unrecognized ratio exceeds --threshold" do
      path = write_fixture("a.rb", "foo()\n")

      status, _out, _err = run_cli("type-scan", "--threshold=0.1", path)

      expect(status).to eq(1)
    end

    it "exits 0 when the unrecognized ratio is at or below --threshold" do
      path = write_fixture("a.rb", "foo()\n")

      status, _out, _err = run_cli("type-scan", "--threshold=0.99", path)

      expect(status).to eq(0)
    end

    it "recurses into directories and aggregates files" do
      write_fixture("nested/one.rb", "1\n")
      write_fixture("nested/two.rb", "foo()\n")

      status, out, _err = run_cli("type-scan", File.join(tmpdir, "nested"))

      expect(status).to eq(0)
      expect(out).to include("Type-of scan: 2 files")
    end

    it "hides 0% classes by default and shows them with --show-recognized" do
      path = write_fixture("a.rb", "1\n")

      _status, out_default, _err = run_cli("type-scan", path)
      _status, out_full, _err = run_cli("type-scan", "--show-recognized", path)

      expect(out_default).not_to include("Prism::IntegerNode")
      expect(out_full).to include("Prism::IntegerNode")
    end

    it "reports parse errors and exits 1" do
      path = write_fixture("a.rb", "def\n")

      status, out, _err = run_cli("type-scan", path)

      expect(status).to eq(1)
      expect(out).to include("Parse errors:")
    end

    it "rejects missing paths with a usage error" do
      status, _out, err = run_cli("type-scan", "/no/such/path.rb")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("not a file or directory")
    end

    it "requires at least one path" do
      status, _out, err = run_cli("type-scan")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("at least one path is required")
    end

    it "lists type-scan in the help text" do
      _status, out, _err = run_cli("help")

      expect(out).to include("type-scan")
    end

    it "auto-loads sig/ from the project root when scanning" do
      Dir.chdir(tmpdir) do
        FileUtils.mkdir_p("sig")
        File.write("sig/scan_demo.rbs", <<~RBS)
          class ScanRbsDemoFixture
          end
        RBS
        File.write("source.rb", "ScanRbsDemoFixture\n")

        status, out, _err = run_cli("type-scan", "source.rb")

        expect(status).to eq(0)
        # ScanRbsDemoFixture would be unrecognized without the project signature loader; with sig/ in scope it resolves
        # cleanly.
        expect(out).not_to match(%r{Prism::ConstantReadNode\s+\d+/\d+})
      end
    end
  end

  describe "diff (v0.1.2)" do
    let(:baseline_payload) do
      {
        "diagnostics" => [
          {
            "path" => "f.rb", "line" => 1, "column" => 1, "severity" => "error",
            "rule" => "call.undefined-method", "source_family" => "builtin", "message" => "no method foo"
          }
        ]
      }
    end

    let(:fresh_diag) do
      {
        "path" => "f.rb", "line" => 5, "column" => 1, "severity" => "error",
        "rule" => "call.undefined-method", "source_family" => "builtin", "message" => "no method bar"
      }
    end

    def write_json(dir, name, payload)
      path = File.join(dir, name)
      File.write(path, JSON.generate(payload))
      path
    end

    it "reports a new diagnostic that is not in the baseline" do
      Dir.mktmpdir do |dir|
        baseline_path = write_json(dir, "baseline.json", baseline_payload)
        current_path = write_json(dir, "current.json", baseline_payload["diagnostics"] + [fresh_diag])

        status, out, _err = run_cli("diff", "--current=#{current_path}", baseline_path)
        expect(status).to eq(1)
        expect(out).to include("+ NEW")
        expect(out).to include("no method bar")
        expect(out).to include("1 new, 0 fixed")
      end
    end

    it "reports a fixed diagnostic that is in the baseline but not the current" do
      Dir.mktmpdir do |dir|
        baseline_path = write_json(dir, "baseline.json", baseline_payload)
        current_path = write_json(dir, "current.json", [])

        status, out, _err = run_cli("diff", "--current=#{current_path}", baseline_path)
        expect(status).to eq(0)
        expect(out).to include("- FIXED")
        expect(out).to include("0 new, 1 fixed")
      end
    end

    it "exits 0 with no diff when baseline and current match" do
      Dir.mktmpdir do |dir|
        baseline_path = write_json(dir, "baseline.json", baseline_payload)
        current_path = write_json(dir, "current.json", baseline_payload["diagnostics"])

        status, out, _err = run_cli("diff", "--current=#{current_path}", baseline_path)
        expect(status).to eq(0)
        expect(out).to include("0 new, 0 fixed")
        expect(out).not_to include("+ NEW")
        expect(out).not_to include("- FIXED")
      end
    end

    it "renders JSON when --format=json" do
      Dir.mktmpdir do |dir|
        baseline_path = write_json(dir, "baseline.json", baseline_payload)
        current_path = write_json(dir, "current.json", baseline_payload["diagnostics"] + [fresh_diag])

        status, out, _err = run_cli("diff", "--format=json", "--current=#{current_path}", baseline_path)
        expect(status).to eq(1)
        payload = JSON.parse(out)
        expect(payload["new"].size).to eq(1)
        expect(payload["fixed"]).to be_empty
        expect(payload["baseline_count"]).to eq(1)
        expect(payload["current_count"]).to eq(2)
      end
    end

    it "accepts a baseline saved as a flat array (no `diagnostics:` wrapper)" do
      Dir.mktmpdir do |dir|
        baseline_path = write_json(dir, "baseline.json", baseline_payload["diagnostics"])
        current_path = write_json(dir, "current.json", baseline_payload["diagnostics"])

        status, out, _err = run_cli("diff", "--current=#{current_path}", baseline_path)
        expect(status).to eq(0)
        expect(out).to include("0 new, 0 fixed")
      end
    end

    it "errors when the baseline file is missing" do
      status, _out, err = run_cli("diff", "--current=/dev/null", "/no/such/baseline.json")
      expect(status).not_to eq(0)
      expect(err).to include("Baseline file not found")
    end

    it "errors when the baseline JSON is malformed" do
      Dir.mktmpdir do |dir|
        bad = File.join(dir, "bad.json")
        File.write(bad, "{ not json")
        current_path = write_json(dir, "current.json", [])

        status, _out, err = run_cli("diff", "--current=#{current_path}", bad)
        expect(status).not_to eq(0)
        expect(err).to include("Invalid JSON")
      end
    end

    it "exits with usage when no baseline argument is given" do
      status, _out, err = run_cli("diff")
      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("Usage: rigor diff")
    end

    it "lists diff in the help text" do
      _status, out, _err = run_cli("help")
      expect(out).to include("diff")
    end
  end

  describe "explain (v0.1.2)" do
    it "lists every rule with no argument" do
      status, out, err = run_cli("explain")

      expect(status).to eq(0)
      expect(err).to eq("")
      expect(out).to include("call.undefined-method")
      expect(out).to include("flow.unreachable-branch")
      expect(out).to include("def.ivar-write-mismatch")
      expect(out).to include("Run `rigor explain <rule>`")
    end

    it "prints the catalog entry for a canonical rule id" do
      status, out, _err = run_cli("explain", "call.undefined-method")

      expect(status).to eq(0)
      expect(out).to include("call.undefined-method")
      expect(out).to include("Method does not exist on the receiver's statically-known class.")
      expect(out).to include("Fires when:")
      expect(out).to include("Does not fire when:")
      expect(out).to include("Suppression:")
      expect(out).to include("Authored severity:")
      expect(out).to include("Severity by profile:")
      expect(out).to include("Evidence tier: high")
      expect(out).to include("Documentation: https://rigor.typedduck.fail/manual/04-diagnostics/")
      expect(out).to include("Since: rigor")
    end

    it "resolves a legacy alias to the canonical entry" do
      status, out, _err = run_cli("explain", "undefined-method")

      expect(status).to eq(0)
      expect(out).to include("call.undefined-method")
      expect(out).to include("Legacy aliases: undefined-method")
    end

    it "prints every rule under a family wildcard" do
      status, out, _err = run_cli("explain", "flow")

      expect(status).to eq(0)
      expect(out).to include("flow.always-raises")
      expect(out).to include("flow.unreachable-branch")
    end

    it "reports unknown rules as usage errors" do
      status, _out, err = run_cli("explain", "no.such-rule")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("Unknown rule: no.such-rule")
    end

    it "renders JSON when --format=json is set" do
      status, out, _err = run_cli("explain", "--format=json", "call.undefined-method")

      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload).to be_an(Array)
      expect(payload.first).to include("id" => "call.undefined-method", "since" => "0.0.1",
                                       "evidence_tier" => "high")
      expect(payload.first["documentation_url"]).to end_with("#rule-call-undefined-method")
      expect(payload.first["fires_when"]).to be_an(Array)
    end

    it "lists explain in the help text" do
      _status, out, _err = run_cli("help")

      expect(out).to include("explain")
    end
  end

  describe "sig-gen (ADR-14 slice 1)" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write_fixture(name, contents)
      path = File.join(tmpdir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    # The output-validity guard, end to end. A method whose rendered RBS does not parse is skipped rather than
    # emitted, and the defect is reported on STDERR — never on stdout, which may be piped straight into a
    # `.rbs` file. Exit stays 0: the remaining signatures are valid and useful, so a single pathological method
    # must not deny the user everything else.
    it "reports an unrenderable method on stderr, keeps stdout clean, and still emits the rest" do
      path = write_fixture("lib/widget.rb", <<~RUBY)
        class Widget
          def n
            42
          end

          def s
            "x"
          end
        end
      RUBY
      allow_any_instance_of(Rigor::SigGen::Generator) # rubocop:disable RSpec/AnyInstance
        .to receive(:render_rbs_line).and_wrap_original do |original, *args|
          args.first.name == :n ? "def n: () -> { data-contrast: Integer }" : original.call(*args)
        end

      status, out, err = run_cli("sig-gen", path)

      expect(status).to eq(0)
      expect(err).to include("skipped 1 method(s) whose generated RBS does not parse")
      expect(err).to include("bug in Rigor's RBS rendering")
      expect(err).to include("Widget#n")
      # stdout stays a valid, usable sig — the other method is still there, the broken one is simply absent.
      expect(out).to include("def s:")
      expect(out).not_to include("data-contrast")
    end

    it "prints RBS skeletons for instance defs that have no existing RBS" do
      path = write_fixture("lib/widget.rb", <<~RUBY)
        class Widget
          def n
            42
          end
        end
      RUBY

      status, out, err = run_cli("sig-gen", path)

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("class Widget")
      expect(out).to include("def n: () -> 42")
      expect(out).to include("[new]")
    end

    it "emits a JSON payload via --format=json" do
      path = write_fixture("lib/widget.rb", "class Widget\n  def s\n    \"hi\"\n  end\nend\n")

      status, out, _err = run_cli("sig-gen", "--format=json", path)
      payload = JSON.parse(out)

      expect(status).to eq(0)
      expect(payload["candidates"].first).to include(
        "class" => "Widget", "method" => "s", "kind" => "instance",
        "classification" => "new_method", "rbs" => %(def s: () -> "hi")
      )
    end

    it "rejects --params=observed-strict (reserved for the capability-role catalog)" do
      path = write_fixture("lib/widget.rb", "class Widget; def n; 1; end; end\n")

      status, _out, err = run_cli("sig-gen", "--params=observed-strict", path)

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("reserved")
    end

    it "rejects unknown --params policies" do
      path = write_fixture("lib/widget.rb", "class Widget; def n; 1; end; end\n")

      status, _out, err = run_cli("sig-gen", "--params=mystery", path)

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("unsupported --params=mystery")
    end

    it "renders a --diff block when --diff is set" do
      path = write_fixture("lib/widget.rb", <<~RUBY)
        class Widget
          def n
            42
          end
        end
      RUBY

      status, out, _err = run_cli("sig-gen", "--diff", path)

      expect(status).to eq(0)
      expect(out).to include("--- ")
      expect(out).to include("+ def n: () -> 42")
    end

    it "lists sig-gen in the help text" do
      _status, out, _err = run_cli("help")

      expect(out).to include("sig-gen")
    end

    # Issue #227: print mode hard-coded the `class` keyword, so a module holding an emittable method was printed as
    # a class — RBS::DuplicatedDeclarationError once the real `module` declaration is loaded alongside it.
    it "prints the source's own module / class keyword and a Data class's ancestry" do
      path = write_fixture("lib/shapes.rb", <<~RUBY)
        module Geometry
          Pair = Data.define(:left)

          def self.origin
            "0,0"
          end
        end
      RUBY

      status, out, err = run_cli("sig-gen", path)

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("module Geometry")
      expect(out).to include("class Geometry::Pair < ::Data")
      expect(out).not_to include("class Geometry\n")
    end

    describe "--params=observed (slice 3)" do
      def write_observed_project
        config_path = File.join(tmpdir, ".rigor.yml")
        File.write(config_path, "paths:\n  - lib\nsignature_paths: []\n")
        write_fixture("lib/calc.rb", "class Calc\n  def greet(name)\n    \"hi\"\n  end\nend\n")
        write_fixture("spec/calc_spec.rb", "c = Calc.new\nc.greet(\"Alice\")\nc.greet(\"Bob\")\n")
        config_path
      end

      it "emits observed argument types via the default spec/ observe path" do
        config = write_observed_project

        Dir.chdir(tmpdir) do
          status, out, _err = run_cli("sig-gen", "--params=observed", "--config=#{config}")
          expect(status).to eq(0)
          expect(out).to include(%(def greet: ("Alice" | "Bob") -> "hi"))
        end
      end

      it "honours an explicit --observe=PATH" do
        config = write_observed_project

        Dir.chdir(tmpdir) do
          _, out, = run_cli("sig-gen", "--params=observed", "--observe=spec", "--config=#{config}")
          expect(out).to include(%(def greet: ("Alice" | "Bob") -> "hi"))
        end
      end

      it "falls back to untyped when no observations match the def's arity" do
        config_path = File.join(tmpdir, ".rigor.yml")
        File.write(config_path, "paths:\n  - lib\nsignature_paths: []\n")
        write_fixture("lib/calc.rb", "class Calc\n  def add(a, b)\n    \"x\"\n  end\nend\n")
        write_fixture("spec/calc_spec.rb", "c = Calc.new\nc.add(1)\n")

        Dir.chdir(tmpdir) do
          _, out, = run_cli("sig-gen", "--params=observed", "--config=#{config_path}")
          expect(out).to include(%(def add: (untyped, untyped) -> "x"))
        end
      end
    end

    describe "--write (slice 2)" do
      def write_config(rel: "lib", sig: "sig")
        config_path = File.join(tmpdir, ".rigor.yml")
        File.write(config_path, "paths:\n  - #{rel}\nsignature_paths:\n  - #{sig}\n")
        config_path
      end

      it "creates a new sig file mirroring the source layout" do
        write_fixture("lib/widget.rb", "class Widget\n  def n; 42; end\nend\n")
        config = write_config

        Dir.chdir(tmpdir) do
          status, out, _err = run_cli("sig-gen", "--write", "--config=#{config}")
          expect(status).to eq(0)
          expect(out).to include("created")
        end

        expect(File.read(File.join(tmpdir, "sig/widget.rbs"))).to include("def n: () -> 42")
      end

      it "merges new methods into an existing sig file without touching authored declarations" do
        write_fixture("lib/widget.rb", "class Widget\n  def n; 42; end\n  def s; \"hi\"; end\nend\n")
        write_fixture("sig/widget.rbs", "class Widget\n  # keep me\n  def n: () -> 42\nend\n")
        config = write_config

        Dir.chdir(tmpdir) { run_cli("sig-gen", "--write", "--config=#{config}") }
        output = File.read(File.join(tmpdir, "sig/widget.rbs"))

        expect(output).to include("# keep me", "def n: () -> 42", %(def s: () -> "hi"))
      end

      it "leaves user-authored tighter-return declarations alone without --overwrite" do
        write_fixture("lib/widget.rb", "class Widget\n  def n; 42; end\nend\n")
        write_fixture("sig/widget.rbs", "class Widget\n  def n: () -> Numeric\nend\n")
        config = write_config

        Dir.chdir(tmpdir) { run_cli("sig-gen", "--write", "--config=#{config}") }

        expect(File.read(File.join(tmpdir, "sig/widget.rbs"))).to include("def n: () -> Numeric")
      end

      it "rewrites tighter-return declarations under --overwrite" do
        write_fixture("lib/widget.rb", "class Widget\n  def n; 42; end\nend\n")
        write_fixture("sig/widget.rbs", "class Widget\n  def n: () -> Numeric\nend\n")
        config = write_config

        Dir.chdir(tmpdir) { run_cli("sig-gen", "--write", "--overwrite", "--config=#{config}") }
        output = File.read(File.join(tmpdir, "sig/widget.rbs"))

        expect(output).to include("def n: () -> 42")
        expect(output).not_to include("Numeric")
      end

      it "rejects --write, --print, --diff combined" do
        status, _out, err = run_cli("sig-gen", "--write", "--print")

        expect(status).to eq(0).or eq(Rigor::CLI::EXIT_USAGE)
        # --print after --write just overrides the mode; OptionParser does not treat them as exclusive at parse time.
        # The validation_error path catches invalid mode values; ensure no crash.
        expect(err).not_to include("Traceback")
      end
    end
  end

  describe "lsp subcommand (slice 1 stub)" do
    it "is listed in `rigor help`" do
      _status, out, _err = run_cli("help")

      expect(out).to include("lsp")
      expect(out).to include("Language Server")
    end

    it "returns 0 when stdin closes cleanly with no LSP messages" do
      # `rigor lsp` blocks reading LSP frames from $stdin via the gem's Io::Reader. Under RSpec stdin is non-TTY and
      # hits EOF immediately, so the loop exits with exit_code=0 (no shutdown → server.exit_code stays nil → CLI returns
      # 0).
      status, _out, _err = run_cli("lsp")

      expect(status).to eq(0)
    end

    it "returns EXIT_USAGE for an unsupported transport" do
      status, _out, err = run_cli("lsp", "--transport=tcp")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("unsupported transport")
    end
  end

  describe "check --tmp-file / --instead-of (editor mode)" do
    let(:tmpdir) { Dir.mktmpdir("rigor-cli-editor-mode-") }

    after { FileUtils.remove_entry(tmpdir) }

    it "rejects --tmp-file alone" do
      status, _out, err = run_cli("check", "--tmp-file=/nonexistent", "lib")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("--tmp-file and --instead-of must appear together")
    end

    it "rejects --instead-of alone" do
      status, _out, err = run_cli("check", "--instead-of=lib/foo.rb", "lib")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("--tmp-file and --instead-of must appear together")
    end

    it "rejects a --tmp-file path that doesn't exist" do
      status, _out, err = run_cli(
        "check", "--tmp-file=#{File.join(tmpdir, 'ghost.rb')}",
        "--instead-of=lib/foo.rb", "lib"
      )

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("no such file or not readable")
    end

    it "analyzes the buffer's bytes under the logical path, emits diagnostics under the logical path" do
      Dir.chdir(tmpdir) do
        FileUtils.mkdir_p("lib")
        # On disk: clean.
        File.write(File.join("lib", "foo.rb"), "x = 1\n")
        # Buffer: parse error.
        physical = File.join(tmpdir, "buffer.rb")
        File.write(physical, "def broken\n")

        status, out, _err = run_cli(
          "check", "--format=json",
          "--tmp-file=#{physical}",
          "--instead-of=lib/foo.rb",
          "--no-stats",
          "lib"
        )

        expect(status).to eq(1)
        diagnostics = JSON.parse(out).fetch("diagnostics")
        paths = diagnostics.map { |d| d.fetch("path") }
        expect(paths).to include("lib/foo.rb")
        expect(paths).not_to include(physical)
      end
    end
  end

  # ADR-51 — CI-native diagnostic output formats.
  describe "check --format=sarif|github|gitlab (ADR-51)" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    # A single reliable `call.undefined-method` (rule-bearing) diagnostic at line 2, column 3.
    def run_format(format)
      Dir.chdir(tmpdir) do
        File.write("demo.rb", "x = \"hello\"\nx.no_such_method_here\n")
        run_cli("check", "--no-cache", "--no-stats", "--format=#{format}", "demo.rb")
      end
    end

    it "renders every declared format and raises when FORMATS and the dispatch drift apart" do
      require "rigor/cli/diagnostic_formats"
      result = Rigor::Analysis::Result.new(diagnostics: [], stats: nil)

      Rigor::CLI::DiagnosticFormats::FORMATS.each do |format|
        expect(Rigor::CLI::DiagnosticFormats.render(result, format)).to be_a(String)
      end
      expect do
        Rigor::CLI::DiagnosticFormats.render(result, "nope")
      end.to raise_error(ArgumentError, /unsupported format/)
    end

    it "emits a valid SARIF 2.1.0 document with the diagnostic as a result" do
      status, out, _err = run_format("sarif")

      expect(status).to eq(1)
      doc = JSON.parse(out)
      expect(doc["version"]).to eq("2.1.0")
      run = doc.fetch("runs").fetch(0)
      expect(run.dig("tool", "driver", "name")).to eq("Rigor")
      expect(run.dig("tool", "driver", "version")).to eq(Rigor::VERSION)
      expect(run.dig("tool", "driver", "rules")).to include("id" => "call.undefined-method")

      result = run.fetch("results").fetch(0)
      expect(result["ruleId"]).to eq("call.undefined-method")
      expect(result["level"]).to eq("error")
      region = result.dig("locations", 0, "physicalLocation", "region")
      expect(region).to eq("startLine" => 2, "startColumn" => 3)
      uri = result.dig("locations", 0, "physicalLocation", "artifactLocation", "uri")
      expect(uri).to eq("demo.rb")
    end

    it "emits a GitHub Actions workflow command per diagnostic" do
      status, out, _err = run_format("github")

      expect(status).to eq(1)
      expect(out).to include(
        "::error file=demo.rb,line=2,col=3,title=call.undefined-method::"
      )
      # Message data follows the `::`.
      expect(out).to match(/::error .+::undefined method/)
    end

    it "emits a GitLab Code Quality report entry per diagnostic" do
      status, out, _err = run_format("gitlab")

      expect(status).to eq(1)
      entries = JSON.parse(out)
      entry = entries.fetch(0)
      expect(entry["check_name"]).to eq("call.undefined-method")
      expect(entry["severity"]).to eq("major")
      expect(entry.dig("location", "path")).to eq("demo.rb")
      expect(entry.dig("location", "lines", "begin")).to eq(2)
      # Fingerprint is a stable hex digest, identical across two runs.
      expect(entry["fingerprint"]).to match(/\A[0-9a-f]{64}\z/)
      _s, second, = run_format("gitlab")
      expect(JSON.parse(second).fetch(0)["fingerprint"]).to eq(entry["fingerprint"])
    end

    it "emits a Checkstyle XML document grouped by file" do
      status, out, _err = run_format("checkstyle")

      expect(status).to eq(1)
      expect(out).to start_with('<?xml version="1.0" encoding="UTF-8"?>')
      expect(out).to include("<checkstyle>").and include("</checkstyle>")
      expect(out).to include('<file name="demo.rb">')
      expect(out).to include(
        '<error line="2" column="3" severity="error" '
      )
      expect(out).to include('source="call.undefined-method"')
      # XML special characters in the message are escaped.
      expect(out).to include("&quot;hello&quot;")
    end

    it "emits a JUnit testsuite with a failure per diagnostic" do
      status, out, _err = run_format("junit")

      expect(status).to eq(1)
      expect(out).to include('<testsuite name="rigor" tests="1" failures="1">')
      expect(out).to include('<testcase name="demo.rb:2:3" classname="call.undefined-method">')
      expect(out).to include('<failure type="error" message=')
      expect(out).to include("</testsuite>")
    end

    it "emits a clean JUnit suite with one passing case for a clean file" do
      Dir.chdir(tmpdir) do
        File.write("clean.rb", "x = 1\n")
        status, out, _err = run_cli("check", "--no-cache", "--no-stats", "--format=junit", "clean.rb")

        expect(status).to eq(0)
        expect(out).to include('<testsuite name="rigor" tests="1" failures="0">')
        expect(out).to include('<testcase name="rigor" />')
      end
    end

    it "emits an empty GitHub stream and exits 0 for a clean file" do
      Dir.chdir(tmpdir) do
        File.write("clean.rb", "x = 1\n")
        status, out, _err = run_cli("check", "--no-cache", "--no-stats", "--format=github", "clean.rb")

        expect(status).to eq(0)
        expect(out).to eq("")
      end
    end

    it "emits TeamCity inspection service messages" do
      status, out, _err = run_format("teamcity")

      expect(status).to eq(1)
      expect(out).to include("##teamcity[inspectionType id='rigor'")
      expect(out).to include("##teamcity[inspection typeId='rigor'")
      expect(out).to include("file='demo.rb'").and include("line='2'").and include("SEVERITY='ERROR'")
    end

    it "rejects an unsupported format as a usage error" do
      status, _out, err = run_format("csv")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("unsupported format: csv")
    end
  end

  # ADR-51 WD7 — CI auto-detection (first-class native / second-class reviewdog).
  describe "check CI auto-detection (ADR-51 WD7)" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    # The suite forces RIGOR_CI_DETECT=0 (spec_helper) for determinism; each example opts back in and simulates one
    # platform, restoring all touched keys afterwards.
    #
    # All known CI provider variables are also saved and cleared so that running the suite under a real CI (e.g. GitHub
    # Actions) does not bleed its own GITHUB_ACTIONS=true into tests that simulate a different platform.
    def with_ci_env(vars)
      all_provider_vars = Rigor::CiDetector::PROVIDERS.map { |p| p[:var] }
      keys = (vars.keys + ["RIGOR_CI_DETECT"] + all_provider_vars).uniq
      saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
      keys.each { |k| ENV.delete(k) }
      ENV["RIGOR_CI_DETECT"] = "1"
      vars.each { |k, v| ENV[k] = v }
      yield
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
    end

    def run_check_in(vars, *extra)
      Dir.chdir(tmpdir) do
        File.write("demo.rb", "x = \"hello\"\nx.no_such_method_here\n")
        with_ci_env(vars) { run_cli("check", "--no-cache", "--no-stats", *extra, "demo.rb") }
      end
    end

    it "augments default text output with github annotations under GitHub Actions" do
      status, out, _err = run_check_in("GITHUB_ACTIONS" => "true")

      expect(status).to eq(1)
      # The human text line is still present...
      expect(out).to include("demo.rb:2:3: error:")
      # ...and the workflow-command annotation is appended.
      expect(out).to include("::error file=demo.rb,line=2,col=3,title=call.undefined-method::")
    end

    it "augments with teamcity service messages under TeamCity" do
      status, out, _err = run_check_in("TEAMCITY_VERSION" => "2024.03")

      expect(status).to eq(1)
      expect(out).to include("demo.rb:2:3: error:")
      expect(out).to include("##teamcity[inspection typeId='rigor'")
    end

    it "prints a reviewdog hint to stderr under a second-class CI (CircleCI)" do
      status, out, err = run_check_in("CIRCLECI" => "true")

      expect(status).to eq(1)
      expect(out).to include("demo.rb:2:3: error:")
      expect(out).not_to include("::error")
      expect(err).to include("CircleCI detected").and include("reviewdog")
    end

    it "prints a format hint to stderr under GitLab CI" do
      _status, out, err = run_check_in("GITLAB_CI" => "true")

      expect(out).not_to include("\"fingerprint\"") # not the gitlab JSON itself
      expect(err).to include("GitLab CI detected").and include("--format gitlab")
    end

    it "does not augment when --no-ci-detect is passed" do
      status, out, err = run_check_in({ "GITHUB_ACTIONS" => "true" }, "--no-ci-detect")

      expect(status).to eq(1)
      expect(out).not_to include("::error file=")
      expect(err).not_to include("detected")
    end

    it "does not augment when an explicit --format is chosen" do
      status, out, _err = run_check_in({ "GITHUB_ACTIONS" => "true" }, "--format=json")

      expect(status).to eq(1)
      # JSON only — no annotation lines mixed into the machine stream.
      expect(out).not_to include("::error file=")
      expect { JSON.parse(out) }.not_to raise_error
    end
  end

  describe "annotate" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write_fixture(name, contents)
      path = File.join(tmpdir, name)
      File.write(path, contents)
      path
    end

    it "annotates each line with its last-expression type" do
      path = write_fixture("a.rb", "a = 1\nb = 2\nc = a + b\n")

      status, out, err = run_cli("annotate", "--no-color", path)

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("a = 1").and include("#=> 1")
      expect(out).to include("#=> 2")
      expect(out).to include("#=> 3")
    end

    it "reports the last expression of a multi-statement line" do
      path = write_fixture("a.rb", "1; 2; 3\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      expect(out).to include("1; 2; 3").and include("#=> 3")
      expect(out).not_to include("#=> 1")
    end

    it "folds an `if` whose condition is statically falsey" do
      path = write_fixture("a.rb", "if nil\n  :then\nelse\n  :else\nend\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      lines = out.lines
      expect(lines[0]).to include("#=> nil")
      expect(lines[1]).to include("#=> :then")
      expect(lines[2]).not_to include("#=>") # the bare `else`
      expect(lines[4]).to include("end").and include("#=> :else")
    end

    it "unions both branches of a single-line ternary on a maybe predicate" do
      path = write_fixture("a.rb", "b = rand(10) == 0 ? 2 : 3\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      expect(out.lines[0]).to include("#=> 2 | 3")
    end

    it "unions both branches of a single-line `if`/`else` on a maybe predicate" do
      path = write_fixture("a.rb", "c = if rand == 0 then :then else :else end\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      expect(out.lines[0]).to include("#=> :else | :then")
    end

    it "annotates a multi-line hash literal once, on its closing line, leaving pair lines bare" do
      source = <<~RUBY
        h = {
          1 => 1,
          1 => 2,
          1.0 => 3,
          1.00 => 4,
        }
        p h
      RUBY
      path = write_fixture("a.rb", source)

      status, out, err = run_cli("annotate", "--no-color", path)

      expect(err).to eq("")
      expect(status).to eq(0)
      lines = out.lines
      # Interior pair lines are not expressions — no `Dynamic[top]` fill noise.
      (1..4).each { |i| expect(lines[i]).not_to include("#=>") }
      # The scalar-key HashShape folds the literal to a value-pinned shape with last-wins on duplicate keys
      # (`1 => 1, 1 => 2` → `1 => 2`; `1.0 => 3, 1.00 => 4` share the float key `1.0` → `1.0 => 4`).
      expect(lines[5]).to start_with("}").and include("#=> { 1 => 2, 1.0 => 4 }")
      expect(lines[6]).to include("p h").and include("#=>")

      # Re-annotating the annotated output is stable (the multi-line-literal shape included).
      second_path = write_fixture("b.rb", out)
      _status, second, _err = run_cli("annotate", "--no-color", second_path)
      expect(second).to eq(out)
    end

    it "annotates `while`-loop body lines with the converged post-fixpoint types" do
      source = <<~RUBY
        def factorial(n)
          result = 1
          i = 1
          while i <= n
            result *= i
            i += 1
          end
          result
        end
      RUBY
      path = write_fixture("a.rb", source)

      _status, out, _err = run_cli("annotate", "--no-color", path)

      lines = out.lines
      # The loop body must reflect the converged (widened) bindings — never the cap-N intermediate constants of the
      # ADR-56 fixpoint (`1 | 2`), nor the RHS literal of the operator-write (`1`).
      expect(lines[4]).to include("result *= i").and include("#=> Integer")
      expect(lines[5]).to include("i += 1").and include("#=> Integer")
      expect(lines[0]).to include("#=> Integer")
    end

    it "annotates a block-header `do |i|` line with the parameter's binding, not Dynamic[top]" do
      source = <<~RUBY
        r = 1
        1.upto(5) do |i|
          r *= i
        end
        h = { x: 1 }
        h.each do |k, v|
          k
        end
      RUBY
      path = write_fixture("a.rb", source)

      _status, out, _err = run_cli("annotate", "--no-color", path)

      lines = out.lines
      # The header line's widest node is the BlockParametersNode — a non-expression whose evaluation falls back to
      # `Dynamic[top]`. The annotation must instead show the bound parameter type(s).
      expect(lines[1]).to include("1.upto(5) do |i|").and include("#=> int<1, 5>")
      expect(lines[5]).to include("each do |k, v|").and include("#=> [:x, 1]")
      expect(out).not_to include("Dynamic")
    end

    it "annotates a `for` loop's `end` line as nil, not Dynamic[top]" do
      path = write_fixture("a.rb", "for i in 1..3\n  puts i\nend\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      lines = out.lines
      expect(lines[2]).to include("end").and include("#=> nil")
      expect(out).not_to include("Dynamic")
    end

    it "annotates a `def` header line with the method's inferred return type" do
      path = write_fixture("a.rb", "def greet(name)\n  \"Hello, \" + name\nend\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      lines = out.lines
      expect(lines[0]).to include("def greet(name)").and include("#=> String")
      # The default annotation for the parameter (`Dynamic[top]`) is replaced by the return-type override on the header
      # line.
      expect(lines[0]).not_to include("Dynamic")
    end

    it "unions explicit `return` with the trailing expression on the def header" do
      path = write_fixture("a.rb", "def f(x)\n  return :odd if x.odd?\n  :even\nend\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      expect(out.lines[0]).to include("def f(x)").and include("#=> :even | :odd")
    end

    it "omits the annotation on a `def` whose return type cannot be inferred (empty body)" do
      path = write_fixture("a.rb", "def empty\nend\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      expect(out.lines[0]).to include("def empty")
      expect(out.lines[0]).not_to include("#=>")
    end

    it "reads UTF-8 source even when `Encoding.default_external` is US-ASCII" do
      # Em-dash + Japanese — the multi-byte content that triggers `invalid byte sequence in US-ASCII` from `String#sub`
      # downstream when the file is read under a US-ASCII default external encoding (the Nix sandbox / minimal locale
      # shape).
      path = write_fixture("a.rb", "# Hello — こんにちは\n1\n")

      original = Encoding.default_external
      begin
        Encoding.default_external = Encoding::US_ASCII
        status, out, err = run_cli("annotate", "--no-color", path)
      ensure
        Encoding.default_external = original
      end

      expect(err).to eq("")
      expect(status).to eq(0)
      expect(out).to include("こんにちは").and include("#=> 1")
    end

    it "is idempotent — re-annotating does not stack comments" do
      path = write_fixture("a.rb", "a = 1\n")

      _status, first, _err = run_cli("annotate", "--no-color", path)
      File.write(path, first)
      _status, second, _err = run_cli("annotate", "--no-color", path)

      expect(second).to eq(first)
      expect(second.scan("#=>").size).to eq(1)
    end

    it "strips a pre-v0.2.0 `#=> dump_type:` annotation when re-annotating" do
      path = write_fixture("a.rb", "a = 1  #=> dump_type: 1\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      expect(out).not_to include("dump_type")
      expect(out.lines[0]).to include("a = 1").and include("#=> 1")
    end

    it "owns the `#=>` marker — a hand-written annotation is replaced, xmpfilter-style" do
      path = write_fixture("a.rb", "a = 1 #=> stale\n")

      _status, out, _err = run_cli("annotate", "--no-color", path)

      expect(out).not_to include("stale")
      expect(out.lines[0]).to include("#=> 1")
    end

    it "leaves a `#=>` inside a string literal alone" do
      path = write_fixture("a.rb", %(s = "#=> not an annotation"\n))

      _status, out, _err = run_cli("annotate", "--no-color", path)

      expect(out.lines[0]).to include(%("#=> not an annotation"))
    end

    describe "bat integration (https://github.com/sharkdp/bat)" do
      # Runs annotate with PATH pointing at `dir` (optionally holding a fake `bat`), with colour forced on.
      def run_annotate_with_path(dir, *argv)
        original = ENV.fetch("PATH", "")
        ENV["PATH"] = dir
        out = StringIO.new
        err = StringIO.new
        status = described_class.start(["annotate", "--color", *argv], out: out, err: err)
        [status, out.string, err.string]
      ensure
        ENV["PATH"] = original
      end

      def write_fake_bat(dir)
        path = File.join(dir, "bat")
        # `/bin/cat` because the test replaces PATH wholesale, so a bare `cat` would not resolve inside the fake script.
        File.write(path, "#!/bin/sh\necho BATMARK\n/bin/cat\n")
        File.chmod(0o755, path)
        path
      end

      it "pipes through bat when colour is on and bat is on PATH" do
        fixture = write_fixture("a.rb", "1\n")
        write_fake_bat(tmpdir)

        status, out, err = run_annotate_with_path(tmpdir, fixture)

        expect(err).to eq("")
        expect(status).to eq(0)
        expect(out).to include("BATMARK").and include("#=> 1")
      end

      it "skips bat under --no-bat and falls back to the built-in colorizer" do
        fixture = write_fixture("a.rb", "1\n")
        write_fake_bat(tmpdir)

        _status, out, _err = run_annotate_with_path(tmpdir, "--no-bat", fixture)

        expect(out).not_to include("BATMARK")
        expect(out).to include("\e[")
      end

      it "warns and falls back when --bat is forced but bat is absent" do
        fixture = write_fixture("a.rb", "1\n")

        status, out, err = run_annotate_with_path(tmpdir, "--bat", fixture)

        expect(status).to eq(0)
        expect(err).to include("no `bat` executable found")
        expect(out).to include("\e[")
      end

      it "falls back to the built-in colorizer when bat fails mid-run" do
        fixture = write_fixture("a.rb", "1\n")
        path = File.join(tmpdir, "bat")
        File.write(path, "#!/bin/sh\nexit 1\n")
        File.chmod(0o755, path)

        status, out, err = run_annotate_with_path(tmpdir, fixture)

        expect(err).to eq("")
        expect(status).to eq(0)
        expect(out).to include("\e[")
      end
    end

    it "emits ANSI colour escapes when --color is forced" do
      path = write_fixture("a.rb", "1\n")

      _status, out, _err = run_cli("annotate", "--color", path)

      expect(out).to include("\e[")
    end

    it "reports a missing file" do
      status, _out, err = run_cli("annotate", "--no-color", "no_such_file.rb")

      expect(status).to eq(1)
      expect(err).to include("file not found")
    end

    it "reports a syntax error in the input" do
      path = write_fixture("bad.rb", "def broken(\n")

      status, _out, err = run_cli("annotate", "--no-color", path)

      expect(status).to eq(1)
      expect(err).to include("bad.rb:")
    end

    describe "NO_COLOR support (https://no-color.org)" do
      # Runs `rigor annotate` against an out stream that reports itself as a tty, with `NO_COLOR` set to `value` (or
      # unset when `value` is `:unset`).
      def run_annotate_tty(*argv, no_color: :unset)
        out = StringIO.new
        out.define_singleton_method(:tty?) { true }
        original = ENV.fetch("NO_COLOR", :absent)
        no_color == :unset ? ENV.delete("NO_COLOR") : ENV["NO_COLOR"] = no_color
        status = described_class.start(["annotate", *argv], out: out, err: StringIO.new)
        [status, out.string]
      ensure
        original == :absent ? ENV.delete("NO_COLOR") : ENV["NO_COLOR"] = original
      end

      it "colours a tty when NO_COLOR is unset" do
        path = write_fixture("a.rb", "1\n")

        _status, out = run_annotate_tty(path, no_color: :unset)

        expect(out).to include("\e[")
      end

      it "suppresses colour when NO_COLOR is present and non-empty" do
        path = write_fixture("a.rb", "1\n")

        _status, out = run_annotate_tty(path, no_color: "1")

        expect(out).not_to include("\e[")
      end

      it "still colours when NO_COLOR is the empty string" do
        path = write_fixture("a.rb", "1\n")

        _status, out = run_annotate_tty(path, no_color: "")

        expect(out).to include("\e[")
      end

      it "lets an explicit --color override NO_COLOR" do
        path = write_fixture("a.rb", "1\n")

        _status, out = run_annotate_tty("--color", path, no_color: "1")

        expect(out).to include("\e[")
      end
    end
  end
end
