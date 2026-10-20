# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/incremental_session"

# Issue #2020 — a run-scoped plugin disclosure ({Rigor::Plugin::Base#disclose_once}) or positioned batch
# ({Rigor::Plugin::Base#emit_once}) registered from the per-file hook exists only while a file is analysed, so an
# `--incremental` recheck that analysed nothing (or only some files) dropped it. Each example drives
# `rigor check --incremental` (one session per simulated process, the real snapshot and store on disk) and
# compares the warm answer with a cold `--no-cache` run's over the same tree.
#
# The fixture plugin memoises what it reads, as every in-tree discloser does: `state.txt` on the first file its
# per-file hook sees, `prepared.txt` in `#prepare`. Only the first file's analysis is therefore credited with the
# read, and the rest reach the disclosure through the memo.
RSpec.describe "IncrementalSession: run-scoped plugin disclosures replay on a recheck (#2020)" do
  before do
    Rigor::Plugin.unregister!
    stub_const("NoticePlugin", notice_plugin)
    %w[alpha bravo charlie].each { |name| source(name, "1") }
    write("state.txt", "broken\n")
    write("prepared.txt", "fine\n")
  end

  after { Rigor::Plugin.unregister! }

  around do |example|
    Dir.mktmpdir("rigor-incremental-disclosures-") do |raw|
      # Realpath'd so the plugin's reads stay inside the trusted-read root (`Dir.pwd`; see #959).
      Dir.chdir(File.realpath(raw)) { example.run }
    end
  end

  let(:cache_root) { File.join(Dir.pwd, ".rigor", "cache") }

  let(:notice_plugin) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "notice", version: "0.1.0")

      def prepare(_services)
        @prepared = read_state("prepared.txt")
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        @state ||= read_state("state.txt")
        disclose_once(:state, message: "notice: state is #{@state}", severity: :warning) if @state != "fine"
        disclose_once(:prepared, message: "notice: prepared is #{@prepared}", severity: :warning) if @prepared != "fine"
        disclose_once(:legacy, message: "notice: legacy code present", severity: :info) if root.slice.include?("legacy")
        if @state.start_with?("view")
          emit_once(:views, [Rigor::Analysis::Diagnostic.new(path: "views/a.erb", line: 2, column: 1,
                                                             message: "notice: #{@state}", severity: :warning,
                                                             rule: "view")])
        end
        []
      end

      private

      def read_state(path)
        io_boundary.read_file(path).strip
      rescue Errno::ENOENT
        "missing"
      end
    end
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def source(name, body)
    write("lib/#{name}.rb", "class #{name.capitalize}\n  def go = #{body}\nend\n")
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => ["lib"], "plugins" => ["rigor-notice"])
    )
  end

  def requirer
    plugin = notice_plugin
    lambda do |_name|
      Rigor::Plugin.register(plugin)
      true
    end
  end

  def fingerprint
    Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: configuration.paths)
  end

  # One `rigor check --incremental` process. Returns `[diagnostics, warm, session]`.
  def incremental_run(workers: 0)
    session = Rigor::Analysis::IncrementalSession.new(
      configuration: configuration, cache_store: Rigor::Cache::Store.new(root: cache_root),
      plugin_requirer: requirer, workers: workers
    )
    diagnostics, warm = guarded_run_incremental(
      session, snapshot: Rigor::Cache::IncrementalSnapshot.new(root: cache_root), fingerprint: fingerprint
    )
    [diagnostics, warm, session]
  end

  def cold
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, plugin_requirer: requirer)
    guarded_run(runner).diagnostics
  end

  def rows(diagnostics) = diagnostics.map(&:to_h)

  def notices(diagnostics)
    rows(diagnostics).filter_map { |row| row["message"] if row["message"].to_s.start_with?("notice:") }
  end

  # The recheck after `change`: its diagnostics, which must be a cold run's, and the files it re-analysed.
  def recheck_after(workers: 0)
    yield
    diagnostics, warm, session = incremental_run(workers: workers)
    expect(warm).to be(true)
    expect(rows(diagnostics)).to eq(rows(cold))
    [diagnostics, session.last_recheck.affected]
  end

  [0, 2].each do |workers|
    context "with --workers #{workers}" do
      before { incremental_run(workers: workers) }

      it "reports the disclosure on a rerun with nothing changed" do
        diagnostics, affected = recheck_after(workers: workers) { nil }
        expect(affected).to be_empty
        expect(notices(diagnostics)).to eq(["notice: state is broken"])
      end

      it "reports it again on the rerun after that" do
        recheck_after(workers: workers) { nil }
        diagnostics, = recheck_after(workers: workers) { nil }
        expect(notices(diagnostics)).to eq(["notice: state is broken"])
      end

      it "drops the disclosure once the input it is about is fixed" do
        diagnostics, = recheck_after(workers: workers) { write("state.txt", "fine\n") }
        expect(notices(diagnostics)).not_to include("notice: state is broken")
        expect(notices(diagnostics)).to be_empty
      end

      it "keeps it fixed on the rerun after the fix" do
        recheck_after(workers: workers) { write("state.txt", "fine\n") }
        diagnostics, affected = recheck_after(workers: workers) { nil }
        expect(affected).to be_empty
        expect(notices(diagnostics)).to be_empty
      end

      it "reports the new message when the input changes but stays broken" do
        diagnostics, = recheck_after(workers: workers) { write("state.txt", "worse\n") }
        expect(notices(diagnostics)).to eq(["notice: state is worse"])
      end
    end
  end

  # A guard: the re-analysed file registers the disclosure afresh, so no line of the #2020 fix makes it fail.
  it "keeps the disclosure when an edit re-analyses only a file that did not read the input" do
    incremental_run
    diagnostics, affected = recheck_after { source("charlie", "2") }
    expect(affected).to eq(Set["lib/charlie.rb"])
    expect(notices(diagnostics)).to eq(["notice: state is broken"])
  end

  it "keeps the disclosure when the file credited with the read is removed" do
    incremental_run
    diagnostics, = recheck_after { FileUtils.rm_f("lib/alpha.rb") }
    expect(notices(diagnostics)).to eq(["notice: state is broken"])
  end

  # The input is read in `#prepare`, so no file's analysis is credited with it; the disclosure is still
  # registered from the per-file hook.
  it "drops a disclosure about an input read in #prepare once that input is fixed" do
    write("prepared.txt", "broken\n")
    incremental_run
    diagnostics, = recheck_after { nil }
    expect(notices(diagnostics)).to include("notice: prepared is broken")
    diagnostics, = recheck_after { write("prepared.txt", "fine\n") }
    expect(notices(diagnostics)).not_to include("notice: prepared is broken")
  end

  # The `legacy` notice is registered only while a file holding `legacy` is analysed: a row about one file's
  # text rather than about an input every file reaches.
  describe "a disclosure only one file registers" do
    before do
      write("state.txt", "fine\n")
      source("bravo", "legacy")
      incremental_run
    end

    it "replays it while an edit re-analyses another file" do
      diagnostics, affected = recheck_after { source("charlie", "2") }
      expect(affected).to eq(Set["lib/charlie.rb"])
      expect(notices(diagnostics)).to eq(["notice: legacy code present"])
    end

    it "drops it once that file is edited not to register it" do
      diagnostics, = recheck_after { source("bravo", "1") }
      expect(notices(diagnostics)).to be_empty
      diagnostics, = recheck_after { nil }
      expect(notices(diagnostics)).to be_empty
    end

    it "drops it once that file is removed" do
      diagnostics, = recheck_after { FileUtils.rm_f("lib/bravo.rb") }
      expect(notices(diagnostics)).to be_empty
      diagnostics, = recheck_after { nil }
      expect(notices(diagnostics)).to be_empty
    end
  end

  describe "a positioned batch (#emit_once)" do
    before { write("state.txt", "view-a\n") }

    it "replays the batch on a rerun with nothing changed" do
      incremental_run
      diagnostics, = recheck_after { nil }
      expect(notices(diagnostics)).to eq(["notice: view-a", "notice: state is view-a"])
    end

    it "drops the batch once its input stops producing it" do
      incremental_run
      diagnostics, = recheck_after { write("state.txt", "fine\n") }
      expect(notices(diagnostics)).to be_empty
    end
  end

  # A guard: no line of the #2020 fix makes it fail. A disclosure the input never called for stays absent.
  it "reports nothing on a clean project's rerun, and the disclosure once the input breaks" do
    write("state.txt", "fine\n")
    incremental_run
    diagnostics, = recheck_after { nil }
    expect(notices(diagnostics)).to be_empty
    diagnostics, = recheck_after { write("state.txt", "broken\n") }
    expect(notices(diagnostics)).to eq(["notice: state is broken"])
  end
end
