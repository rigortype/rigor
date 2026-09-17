# frozen_string_literal: true

require "tempfile"
require "tmpdir"

require "rigor/analysis/baseline"
require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/plugin"

# Issue #1051 — run-scoped plugin disclosures (`Plugin::Base#disclose_once`).
#
# A project-global disclosure ("there is no `db/schema.rb`, so column checks are off") is a fact about
# the run's INPUTS. Before #1051 plugins emitted it from `#diagnostics_for_file` behind a per-instance
# `@emitted` flag, which is per fork-pool WORKER: `--workers 2` produced two copies, each positioned at
# whichever file that worker analysed first — after #393 possibly an `.erb` template unit's path.
#
# The contract this spec pins: one row per `(plugin id, key)` per RUN, at `.rigor.yml:1:1`, identical
# under `--workers 0` and `--workers N`.
RSpec.describe "run-scoped plugin disclosures (#1051)" do
  def diag_keys(diagnostics)
    diagnostics.map { |d| [d.path, d.line, d.column, d.rule, d.source_family, d.message] }.sort
  end

  # #1055 — a pooled run must analyse its files IN the pool. Every Ractor worker used to die in
  # `WorkerSession#initialize` on a class-level `@memo ||= …` (a class-ivar write a non-main Ractor may not
  # perform), so the coordinator re-analysed the whole file set in process and this row was the only thing
  # that said so. The multiset comparisons below would notice too, but only by way of a row they do not name;
  # this asserts the pool actually ran.
  def expect_no_pool_degrade(diagnostics)
    expect(diagnostics.map(&:rule)).not_to include("pool-degraded")
  end

  # Six files so a two-worker split gives each worker a different FIRST file — the condition under which
  # the old per-instance flag positioned its copies differently.
  def write_fixture(dir, count: 6)
    Array.new(count) do |i|
      path = File.join(dir, "file_#{i}.rb")
      File.write(path, "x_#{i} = #{i}\n")
      path
    end
  end

  def run_with(dir, paths, plugin_class, plugin_name, workers: nil)
    configuration = Rigor::Configuration.new("paths" => paths, "plugins" => [plugin_name])
    requirer = lambda do |_name|
      Rigor::Plugin.register(plugin_class)
      true
    end
    Dir.chdir(dir) do
      runner = Rigor::Analysis::Runner.new(
        configuration: configuration,
        cache_store: Rigor::Cache::Store.new(root: File.join(dir, ".rigor")),
        plugin_requirer: requirer,
        **(workers ? { workers: workers } : {})
      )
      guarded_run(runner).diagnostics
    end
  end

  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  describe "Plugin::Base#disclose_once" do
    let(:plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "disclosing-plugin", version: "0.1.0")

        def prepare(_services)
          disclose_once(:schema_missing, message: "schema file not found", severity: :info)
        end
      end
    end

    before { stub_const("RunDisclosureStubPlugin", plugin_class) }

    it "registers a key at most once per instance and keeps registration order" do
      plugin = plugin_class.new(services: nil)
      plugin.disclose_once(:b, message: "second")
      plugin.disclose_once(:a, message: "first")
      plugin.disclose_once(:b, message: "IGNORED — same key")

      expect(plugin.run_disclosure_records.map { |r| r[:key] }).to eq(%w[b a])
      expect(plugin.run_disclosure_records.map { |r| r[:message] }).to eq(%w[second first])
    end

    it "emits exactly one row, at .rigor.yml:1:1, on a sequential run" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        rows = run_with(dir, paths, plugin_class, "rigor-disclosing-plugin")
               .select { |d| d.message == "schema file not found" }

        expect(rows.size).to eq(1)
        expect([rows.first.path, rows.first.line, rows.first.column]).to eq([".rigor.yml", 1, 1])
        expect(rows.first.severity).to eq(:info)
        expect(rows.first.rule).to eq("load-error")
        expect(rows.first.source_family).to eq("plugin.disclosing-plugin")
      end
    end

    it "emits exactly one row under workers: 2, never positioned at an analysed file" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        pooled = run_with(dir, paths, plugin_class, "rigor-disclosing-plugin", workers: 2)
        expect_no_pool_degrade(pooled)

        rows = pooled.select { |d| d.message == "schema file not found" }
        expect(rows.size).to eq(1)
        expect(rows.first.path).to eq(".rigor.yml")
      end
    end

    it "produces the same diagnostic multiset sequentially and pooled" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        sequential = run_with(dir, paths, plugin_class, "rigor-disclosing-plugin")
        pooled = run_with(dir, paths, plugin_class, "rigor-disclosing-plugin", workers: 2)

        expect_no_pool_degrade(pooled)
        expect(diag_keys(pooled)).to eq(diag_keys(sequential))
      end
    end
  end

  describe "a third-party-shaped plugin that discloses from #diagnostics_for_file" do
    # The pre-#1051 emission SITE — the per-file hook, reached once per analysed file and therefore by
    # every worker — with the flag replaced by the keyed facility. The parent's pre-fork session never
    # registers this one (nothing calls `#diagnostics_for_file` before the fork), so the row can only
    # arrive through the workers' payloads and must be de-duplicated on the parent.
    let(:plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "late-disclosing-plugin", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          disclose_once(:routes_missing, message: "routes file not found", severity: :warning)
          []
        end
      end
    end

    before { stub_const("RunDisclosureLateStubPlugin", plugin_class) }

    it "is de-duplicated to one row across workers" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        pooled = run_with(dir, paths, plugin_class, "rigor-late-disclosing-plugin", workers: 2)
        expect_no_pool_degrade(pooled)

        rows = pooled.select { |d| d.message == "routes file not found" }
        expect(rows.size).to eq(1)
        expect([rows.first.path, rows.first.severity]).to eq([".rigor.yml", :warning])
      end
    end

    it "produces the same diagnostic multiset sequentially and pooled" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        sequential = run_with(dir, paths, plugin_class, "rigor-late-disclosing-plugin")
        pooled = run_with(dir, paths, plugin_class, "rigor-late-disclosing-plugin", workers: 2)

        expect_no_pool_degrade(pooled)
        expect(diag_keys(pooled)).to eq(diag_keys(sequential))
      end
    end
  end

  # Issue #1056 — the shape the six bundled discovery plugins (rigor-actioncable, -activejob,
  # -activestorage, -actionmailer, -pundit, -sidekiq) carried: a `load_error_diagnostic(path)` returned
  # from `#diagnostics_for_file` with NO once-guard at all, so the row repeated on every analysed FILE and
  # `--workers N` re-multiplied that by each worker's own instance. A stub plugin suffices here because
  # the pooled path is plugin-agnostic — it de-duplicates by `(plugin id, key)` and never reads a message;
  # each bundled plugin's own integration spec pins its wording and severity sequentially.
  describe "a discovery plugin whose index producer fails (#1056)" do
    let(:plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "failing-index-plugin", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          disclose_once(
            :index_load_failed,
            message: "failing-index-plugin: failed to discover things: RuntimeError: boom",
            severity: :warning,
            rule: "load-error"
          )
          []
        end
      end
    end

    before { stub_const("RunDisclosureFailingIndexStubPlugin", plugin_class) }

    it "emits one row at .rigor.yml:1:1 sequentially, not one per analysed file" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        rows = run_with(dir, paths, plugin_class, "rigor-failing-index-plugin")
               .select { |d| d.rule == "load-error" && d.source_family == "plugin.failing-index-plugin" }

        expect(rows.size).to eq(1)
        expect([rows.first.path, rows.first.line, rows.first.column]).to eq([".rigor.yml", 1, 1])
        expect(rows.first.severity).to eq(:warning)
      end
    end

    it "emits the same single row under workers: 2" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        sequential = run_with(dir, paths, plugin_class, "rigor-failing-index-plugin")
        pooled = run_with(dir, paths, plugin_class, "rigor-failing-index-plugin", workers: 2)

        expect(pooled.count { |d| d.rule == "load-error" }).to eq(1)
        expect(diag_keys(pooled)).to eq(diag_keys(sequential))
      end
    end
  end

  # Issue #1051 review — the position move is a BASELINE-VISIBLE change. `Analysis::Baseline` buckets by
  # `(file, qualified_rule[, message])`, so an entry a project recorded while the disclosure still landed on
  # a controller stops matching once the row moves to `.rigor.yml` and the row surfaces as new (and the
  # rails-i18n / rails-routes ones are `:warning`, so it fails `--fail-on=warning`). The qualified rule is
  # unchanged, so re-keying the entry to `.rigor.yml` is all a regenerated baseline does; this pins both
  # halves so the upgrade note in the changelog and the plugin manuals stays true.
  describe "a committed baseline against the new position" do
    def disclosure_row
      Rigor::Analysis::Diagnostic.new(
        path: ".rigor.yml", line: 1, column: 1,
        message: "rigor-activerecord: schema file `db/schema.rb` not found",
        severity: :info, rule: "load-error", source_family: "plugin.activerecord"
      )
    end

    def baseline_for(file)
      Tempfile.create(["baseline", ".yml"]) do |f|
        f.write(<<~YAML)
          version: 1
          ignored:
            - file: #{file}
              rule: plugin.activerecord.load-error
              count: 1
        YAML
        f.flush
        yield Rigor::Analysis::Baseline.load(f.path)
      end
    end

    it "silences the row when the entry is keyed to .rigor.yml" do
      baseline_for(".rigor.yml") do |baseline|
        surfaced, silenced = baseline.filter([disclosure_row])
        expect(silenced).to eq(1)
        expect(surfaced).to be_empty
      end
    end

    it "does not silence it when the entry is still keyed to the old file position" do
      baseline_for("app/controllers/account_controller.rb") do |baseline|
        surfaced, silenced = baseline.filter([disclosure_row])
        expect(silenced).to eq(0)
        expect(surfaced.map(&:path)).to eq([".rigor.yml"])
      end
    end
  end
end
