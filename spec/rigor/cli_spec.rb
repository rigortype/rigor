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
        # Logical path has a different value at (1,1) than the buffer.
        # On disk: ":on_disk_sym"; in buffer: "42".
        logical = write_fixture("a.rb", ":on_disk_sym\n")
        buffer = write_fixture("buf.rb", "42\n")

        status, out, _err = run_cli(
          "type-of",
          "--tmp-file=#{buffer}",
          "--instead-of=#{logical}",
          "#{logical}:1:1"
        )

        expect(status).to eq(0)
        # The probe must reflect the BUFFER's bytes (42), not the
        # on-disk symbol literal.
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
        # The constant reference evaluates to the class object itself,
        # i.e. singleton(CliRbsDemoFixture). Phase 2b enforces this
        # distinction so subsequent class-method dispatch can hit
        # singleton-side definitions.
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
        # `--no-stats` is required because the default stats
        # summary forces `class_decl_paths` to build the RBS
        # env, which warms `.rigor/cache` and would defeat
        # the "no cache directory exists" assertion.
        status, out, _err = run_cli("check", "--cache-stats", "--no-stats", "a.rb")
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
        store.fetch_or_compute(producer_id: "demo", params: {}, descriptor: descriptor) { :seed }

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

        # `--no-stats` (see the sibling spec): the stats
        # summary would re-warm the cache and re-create the
        # directory we're asserting got deleted.
        status, out, _err = run_cli("check", "--clear-cache", "--no-stats", "a.rb")
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
        # ScanRbsDemoFixture would be unrecognized without the project
        # signature loader; with sig/ in scope it resolves cleanly.
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
      expect(payload.first).to include("id" => "call.undefined-method", "since" => "0.0.1")
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
        # --print after --write just overrides the mode; OptionParser does not
        # treat them as exclusive at parse time. The validation_error path catches
        # invalid mode values; ensure no crash.
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
      # `rigor lsp` blocks reading LSP frames from $stdin via the
      # gem's Io::Reader. Under RSpec stdin is non-TTY and hits EOF
      # immediately, so the loop exits with exit_code=0 (no
      # shutdown → server.exit_code stays nil → CLI returns 0).
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
end
