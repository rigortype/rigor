# frozen_string_literal: true

require "tempfile"
require "tmpdir"

require "rigor/analysis/baseline"
require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/plugin"

# Issue #1060 — run-scoped POSITIONED batches (`Plugin::Base#emit_once`), the sibling of
# `#disclose_once` (#1051, `run_scoped_disclosure_spec.rb`).
#
# A project-wide scan whose rows name real files that are not analysed targets (rigor-rails-i18n's
# view-template scan) used to return its batch from `#diagnostics_for_file` behind a per-instance
# `@emitted` flag, so `--workers N` repeated the whole batch once per fork-pool worker. The contract this
# spec pins: exactly one copy of each row per run, at the row's OWN position, identical under
# `--workers 0` and `--workers N`; first registration of a key wins whole; and a baseline entry keyed to
# the row's own file still silences it (the move is baseline-neutral, unlike #1054 / #1056).
RSpec.describe "run-scoped positioned plugin batches (#1060)" do
  def diag_rows(diagnostics)
    diagnostics.map { |d| [d.path, d.line, d.column, d.severity, d.rule, d.source_family, d.message] }
  end

  def expect_no_pool_degrade(diagnostics)
    expect(diagnostics.map(&:rule)).not_to include("pool-degraded")
  end

  # Six files so a two-worker split gives each worker a different FIRST file — the condition under which
  # the per-instance flag re-emitted the batch once per worker.
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

  def view_row(line, message, path: "app/views/posts/index.html.erb")
    Rigor::Analysis::Diagnostic.new(
      path: path, line: line, column: 3, message: message, severity: :warning, rule: "unknown-key"
    )
  end

  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  describe "Plugin::Base#emit_once" do
    let(:plugin_class) { Class.new(Rigor::Plugin::Base) { manifest(id: "batch-unit-plugin", version: "0.1.0") } }

    it "keeps the first batch registered under a key whole and drops a later one" do
      plugin = plugin_class.new(services: nil)
      plugin.emit_once(:views, [view_row(12, "first"), view_row(14, "second")])
      plugin.emit_once(:views, [view_row(99, "IGNORED — same key")])

      records = plugin.run_disclosure_records
      expect(records.size).to eq(1)
      expect(records.first[:diagnostics].map { |d| [d.line, d.message] }).to eq([[12, "first"], [14, "second"]])
    end

    it "stores frozen copies, so the batch is Marshal-clean and the caller's rows stay untouched" do
      plugin = plugin_class.new(services: nil)
      original = view_row(12, "first")
      plugin.emit_once(:views, [original])

      stored = plugin.run_disclosure_records.first[:diagnostics].first
      expect(stored).to be_frozen
      expect(stored).not_to equal(original)
      expect(original).not_to be_frozen
      expect(Marshal.load(Marshal.dump(plugin.run_disclosure_records)).first[:diagnostics].first.line).to eq(12)
    end

    it "shares one key namespace with #disclose_once" do
      plugin = plugin_class.new(services: nil)
      plugin.disclose_once(:views, message: "a disclosure")
      plugin.emit_once(:views, [view_row(12, "IGNORED — key already taken")])

      expect(plugin.run_disclosure_records.map { |r| r.key?(:diagnostics) }).to eq([false])
    end

    it "rejects a row that is not a Diagnostic" do
      plugin = plugin_class.new(services: nil)

      expect { plugin.emit_once(:views, ["app/views/x.erb:1"]) }.to raise_error(ArgumentError, /Diagnostic/)
      expect(plugin.run_disclosure_records).to be_empty
    end
  end

  describe "a batch registered from #diagnostics_for_file" do
    # The rigor-rails-i18n shape: every analysed file reaches the registration, every worker reaches it, and
    # the rows name a file that is NOT an analysed target. The parent's pre-fork session never registers it,
    # so the batch reaches the parent only through the worker payloads.
    let(:plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "view-scan-plugin", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          emit_once(:view_diagnostics, [
                      Rigor::Analysis::Diagnostic.new(path: "app/views/posts/index.html.erb", line: 12, column: 3,
                                                      message: "unknown key posts.index.title",
                                                      severity: :warning, rule: "unknown-key"),
                      Rigor::Analysis::Diagnostic.new(path: "app/views/home/show.html.erb", line: 4, column: 1,
                                                      message: "unknown key home.show.heading",
                                                      severity: :warning, rule: "unknown-key")
                    ])
          []
        end
      end
    end
    let(:expected_rows) do
      [
        ["app/views/posts/index.html.erb", 12, 3, :warning, "unknown-key", "plugin.view-scan-plugin",
         "unknown key posts.index.title"],
        ["app/views/home/show.html.erb", 4, 1, :warning, "unknown-key", "plugin.view-scan-plugin",
         "unknown key home.show.heading"]
      ]
    end

    before { stub_const("PositionedBatchStubPlugin", plugin_class) }

    def batch_rows(diagnostics)
      diag_rows(diagnostics.select { |d| d.source_family == "plugin.view-scan-plugin" })
    end

    it "emits exactly one copy of each row, at its own position, on a sequential run" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        expect(batch_rows(run_with(dir, paths, plugin_class, "rigor-view-scan-plugin"))).to eq(expected_rows)
      end
    end

    it "emits exactly one copy of each row under workers: 2" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        pooled = run_with(dir, paths, plugin_class, "rigor-view-scan-plugin", workers: 2)

        expect_no_pool_degrade(pooled)
        expect(batch_rows(pooled)).to eq(expected_rows)
      end
    end

    it "produces a byte-identical stream sequentially and pooled" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        sequential = run_with(dir, paths, plugin_class, "rigor-view-scan-plugin")
        pooled = run_with(dir, paths, plugin_class, "rigor-view-scan-plugin", workers: 2)

        expect_no_pool_degrade(pooled)
        expect(diag_rows(pooled)).to eq(diag_rows(sequential))
      end
    end
  end

  describe "a batch whose content differs between plugin instances" do
    # A plugin author is not supposed to do this, but it is how the "never merged row by row" half of the
    # contract becomes observable: each instance's batch names the first file IT analysed. Under the pool
    # the two workers' first files differ, so a row-wise union would emit two rows; the key-wise contract
    # emits one whole batch.
    let(:plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "divergent-batch-plugin", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          @first_seen ||= File.basename(path)
          emit_once(:scan, [Rigor::Analysis::Diagnostic.new(path: "app/views/a.html.erb", line: 1, column: 1,
                                                            message: "seen first: #{@first_seen}",
                                                            severity: :info, rule: "scan")])
          []
        end
      end
    end

    before { stub_const("DivergentBatchStubPlugin", plugin_class) }

    it "keeps exactly one registered batch, never a union of the workers' batches" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        pooled = run_with(dir, paths, plugin_class, "rigor-divergent-batch-plugin", workers: 2)
        expect_no_pool_degrade(pooled)

        rows = pooled.select { |d| d.source_family == "plugin.divergent-batch-plugin" }
        expect(rows.size).to eq(1)
        expect(rows.first.message).to match(/\Aseen first: file_\d\.rb\z/)
      end
    end
  end

  describe "a batch registered from #prepare" do
    # `#prepare` runs on the parent's pre-fork session, so every child inherits the registration and
    # re-offers it in its payload; the parent must drop each re-offer.
    let(:plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "prepared-batch-plugin", version: "0.1.0")

        def prepare(_services)
          emit_once(:schema_columns, [Rigor::Analysis::Diagnostic.new(path: "db/schema.rb", line: 7, column: 5,
                                                                      message: "column type not recognised",
                                                                      severity: :info, rule: "schema")])
        end
      end
    end

    before { stub_const("PreparedBatchStubPlugin", plugin_class) }

    it "survives the fork pool as one copy, identical to the sequential run" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        sequential = run_with(dir, paths, plugin_class, "rigor-prepared-batch-plugin")
        pooled = run_with(dir, paths, plugin_class, "rigor-prepared-batch-plugin", workers: 2)
        expect_no_pool_degrade(pooled)

        rows = pooled.select { |d| d.source_family == "plugin.prepared-batch-plugin" }
        expect(diag_rows(rows)).to eq([["db/schema.rb", 7, 5, :info, "schema", "plugin.prepared-batch-plugin",
                                        "column type not recognised"]])
        expect(diag_rows(pooled)).to eq(diag_rows(sequential))
      end
    end
  end

  # The move from a flag-guarded `#diagnostics_for_file` return to `#emit_once` is baseline-NEUTRAL:
  # `Analysis::Baseline` buckets by `(file, qualified_rule[, message])`, and both are the ones the
  # per-file path produced — the row keeps its file, and the engine stamps the same `plugin.<id>` family.
  describe "a committed baseline keyed to the row's own position" do
    let(:plugin_class) do
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "baselined-batch-plugin", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          emit_once(:views, [Rigor::Analysis::Diagnostic.new(path: "app/views/posts/index.html.erb", line: 12,
                                                             column: 3, message: "unknown key posts.index.title",
                                                             severity: :warning, rule: "unknown-key")])
          []
        end
      end
    end

    before { stub_const("BaselinedBatchStubPlugin", plugin_class) }

    it "still silences the emitted row" do
      Dir.mktmpdir do |dir|
        paths = write_fixture(dir)
        pooled = run_with(dir, paths, plugin_class, "rigor-baselined-batch-plugin", workers: 2)
        rows = pooled.select { |d| d.source_family == "plugin.baselined-batch-plugin" }

        Tempfile.create(["baseline", ".yml"]) do |f|
          f.write(<<~YAML)
            version: 1
            ignored:
              - file: app/views/posts/index.html.erb
                rule: plugin.baselined-batch-plugin.unknown-key
                count: 1
          YAML
          f.flush
          surfaced, silenced = Rigor::Analysis::Baseline.load(f.path).filter(rows)
          expect(silenced).to eq(1)
          expect(surfaced).to be_empty
        end
      end
    end
  end
end
