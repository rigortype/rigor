# frozen_string_literal: true

require "tmpdir"

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
        rows = run_with(dir, paths, plugin_class, "rigor-disclosing-plugin", workers: 2)
               .select { |d| d.message == "schema file not found" }

        expect(rows.size).to eq(1)
        expect(rows.first.path).to eq(".rigor.yml")
      end
    end

    it "produces the same diagnostic multiset sequentially and pooled" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        sequential = run_with(dir, paths, plugin_class, "rigor-disclosing-plugin")
        pooled = run_with(dir, paths, plugin_class, "rigor-disclosing-plugin", workers: 2)

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
        rows = run_with(dir, paths, plugin_class, "rigor-late-disclosing-plugin", workers: 2)
               .select { |d| d.message == "routes file not found" }

        expect(rows.size).to eq(1)
        expect([rows.first.path, rows.first.severity]).to eq([".rigor.yml", :warning])
      end
    end

    it "produces the same diagnostic multiset sequentially and pooled" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        sequential = run_with(dir, paths, plugin_class, "rigor-late-disclosing-plugin")
        pooled = run_with(dir, paths, plugin_class, "rigor-late-disclosing-plugin", workers: 2)

        expect(diag_keys(pooled)).to eq(diag_keys(sequential))
      end
    end
  end
end
