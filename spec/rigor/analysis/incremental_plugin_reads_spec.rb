# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "rigor/analysis/incremental_session"

# Issue #1553 — a plugin read ({Rigor::Plugin::IoBoundary}) made while analysing a file is an input of that file's
# cached rows. The ADR-46 edges record type and declaration reads only, so before #1553 a recheck served the
# reader's rows unchanged after the read input changed. Each example drives `rigor check --incremental` (one
# session per simulated process, the real snapshot and store on disk) and compares the warm answer with a cold
# `--no-cache` run's over the same tree.
#
# The fixture plugin reads what the analysed source asks for: `policy("x")` reads `x`, `probe("x")` asks
# `#file?`, `listing("d")` lists `d`, `globbing("d")` globs `d/*.txt`. A file's read set is therefore its text.
RSpec.describe "IncrementalSession: plugin reads join the affected closure (#1553)" do
  before do
    Rigor::Plugin.unregister!
    stub_const("PolicyReaderPlugin", reader_plugin)
    reader("alpha", "1")
    write("policy.txt", "allow\n")
  end

  after { Rigor::Plugin.unregister! }

  around do |example|
    Dir.mktmpdir("rigor-incremental-reads-") do |raw|
      # Realpath'd so the plugin's reads stay inside the trusted-read root (`Dir.pwd`; see #959).
      Dir.chdir(File.realpath(raw)) { example.run }
    end
  end

  let(:cache_root) { File.join(Dir.pwd, ".rigor", "cache") }

  let(:reader_plugin) do
    Class.new(Rigor::Plugin::Base) do
      manifest(id: "policy-reader", version: "0.1.0")

      node_rule Prism::CallNode do |node, _scope, path|
        argument = node.arguments&.arguments&.first
        next [] unless argument.is_a?(Prism::StringNode)

        target = argument.unescaped
        said =
          case node.name
          when :policy
            begin
              io_boundary.read_file(target).strip
            rescue Errno::ENOENT
              "missing"
            end
          when :probe then io_boundary.file?(target).to_s
          when :listing then io_boundary.list_directory(target).map { |entry| File.basename(entry) }.sort.join(",")
          when :globbing then io_boundary.glob(target, "*.txt").map { |entry| File.basename(entry) }.sort.join(",")
          end
        next [] if said.nil?

        [diagnostic(node, path: path, message: "#{node.name} #{target}: #{said}", severity: :warning, rule: "read")]
      end
    end
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def reader(name, *calls)
    write("lib/#{name}.rb", "class #{name.capitalize}\n  def go\n#{calls.map do |call|
      "    #{call}\n"
    end.join}  end\nend\n")
  end

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => ["lib"], "plugins" => ["rigor-policy-reader"])
    )
  end

  def requirer
    plugin = reader_plugin
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

  def read_messages(diagnostics)
    rows(diagnostics).filter_map { |row| row["message"] if row["rule"].to_s.end_with?("read") }
  end

  # The recheck after `change`: warm, a cold run's answer, and the files it re-analysed.
  def recheck_after(workers: 0)
    yield
    diagnostics, warm, session = incremental_run(workers: workers)
    expect(warm).to be(true)
    expect(rows(diagnostics)).to eq(rows(cold))
    [diagnostics, session.last_recheck.affected]
  end

  # The persisted per-file reads, as `{path => [[kind, path or root/pattern, comparator or mode]]}`: the stat
  # values carry each run's recording instant, so two runs agree on everything but those.
  def persisted_reads
    payload = Rigor::Cache::IncrementalSnapshot.new(root: cache_root).load(fingerprint: fingerprint)
    payload.plugin_reads.transform_values do |rows|
      rows.map do |row|
        if row.is_a?(Rigor::Cache::Descriptor::GlobEntry)
          [:glob, File.basename(row.root), row.pattern, row.mode]
        else
          [:file, File.basename(row.path), row.comparator]
        end
      end.sort
    end
  end

  describe "a read file outside the analysed paths" do
    before do
      reader("charlie", 'policy("policy.txt")')
      incremental_run
    end

    it "re-analyses the reader when the file is edited" do
      diagnostics, affected = recheck_after { write("policy.txt", "deny\n") }
      expect(read_messages(diagnostics)).to eq(["policy policy.txt: deny"])
      expect(affected).to eq(Set["lib/charlie.rb"])
    end

    it "re-analyses the reader when the file is removed" do
      diagnostics, = recheck_after { FileUtils.rm_f("policy.txt") }
      expect(read_messages(diagnostics)).to eq(["policy policy.txt: missing"])
    end

    it "re-analyses the reader when a file that was missing at the read appears" do
      reader("charlie", 'policy("later.txt")')
      recheck_after { nil }
      diagnostics, = recheck_after { write("later.txt", "present\n") }
      expect(read_messages(diagnostics)).to eq(["policy later.txt: present"])
    end

    it "re-analyses the reader when a file an existence probe found absent appears" do
      reader("charlie", 'probe("flag.txt")')
      recheck_after { nil }
      diagnostics, = recheck_after { write("flag.txt", "") }
      expect(read_messages(diagnostics)).to eq(["probe flag.txt: true"])
    end

    it "re-analyses nothing when the read file is left alone" do
      _, affected = recheck_after { reader("alpha", "2") }
      expect(affected).to eq(Set["lib/alpha.rb"])
    end
  end

  it "re-analyses both an analysed file the plugin read and its reader when the read file is edited" do
    reader("charlie", 'policy("lib/alpha.rb")')
    incremental_run
    diagnostics, affected = recheck_after { reader("alpha", "2") }
    expect(affected).to eq(Set["lib/alpha.rb", "lib/charlie.rb"])
    expect(read_messages(diagnostics).first).to include("2")
  end

  describe "a read through a listing" do
    before do
      write("roles/admin.txt", "")
      reader("charlie", 'listing("roles")', 'globbing("roles")')
      incremental_run
    end

    it "re-analyses the reader when a file is added to the listed and globbed directory" do
      diagnostics, = recheck_after { write("roles/guest.txt", "") }
      expect(read_messages(diagnostics)).to eq(["listing roles: admin.txt,guest.txt",
                                                "globbing roles: admin.txt,guest.txt"])
    end

    it "re-analyses the reader through the glob alone (a `:names` row)" do
      reader("charlie", 'globbing("roles")')
      recheck_after { nil }
      diagnostics, = recheck_after { write("roles/guest.txt", "") }
      expect(read_messages(diagnostics)).to eq(["globbing roles: admin.txt,guest.txt"])
    end
  end

  describe "several readers" do
    it "re-analyses every reader of the edited file" do
      reader("charlie", 'policy("policy.txt")')
      reader("delta", 'policy("policy.txt")')
      incremental_run
      diagnostics, affected = recheck_after { write("policy.txt", "deny\n") }
      expect(affected).to eq(Set["lib/charlie.rb", "lib/delta.rb"])
      expect(read_messages(diagnostics)).to eq(["policy policy.txt: deny"] * 2)
    end

    it "stops re-analysing a reader once it no longer reads the file" do
      reader("charlie", 'policy("policy.txt")')
      reader("delta", 'policy("policy.txt")')
      incremental_run
      recheck_after { reader("delta", "1") }
      _, affected = recheck_after { write("policy.txt", "deny\n") }
      expect(affected).to eq(Set["lib/charlie.rb"])
    end

    it "drops a removed reader's reads" do
      reader("charlie", 'policy("policy.txt")')
      incremental_run
      recheck_after { FileUtils.rm_f("lib/charlie.rb") }
      _, affected = recheck_after { write("policy.txt", "deny\n") }
      expect(affected).to be_empty
    end
  end

  describe "under a worker pool" do
    before do
      reader("charlie", 'policy("policy.txt")', 'listing("lib")')
      reader("delta", 'probe("flag.txt")')
    end

    it "records the reads a sequential run records" do
      incremental_run
      sequential = persisted_reads
      FileUtils.rm_rf(cache_root)
      incremental_run(workers: 2)
      expect(sequential.keys).to contain_exactly("lib/charlie.rb", "lib/delta.rb")
      expect(persisted_reads).to eq(sequential)
    end

    it "re-analyses the reader when the read file is edited" do
      incremental_run(workers: 2)
      diagnostics, affected = recheck_after(workers: 2) { write("policy.txt", "deny\n") }
      expect(affected).to eq(Set["lib/charlie.rb"])
      expect(read_messages(diagnostics)).to include("policy policy.txt: deny")
    end
  end

  # The fixture reads the logical path; the boundary records it as given (`File.absolute_path`, not `realpath`).
  it "re-analyses the reader of a symlinked file when the link target is edited" do
    write("real/policy.txt", "allow\n")
    File.symlink(File.join(Dir.pwd, "real", "policy.txt"), "linked.txt")
    reader("charlie", 'policy("linked.txt")')
    incremental_run
    expect(persisted_reads.fetch("lib/charlie.rb")).to eq([[:file, "linked.txt", :stat]])
    diagnostics, = recheck_after { write("real/policy.txt", "deny\n") }
    expect(read_messages(diagnostics)).to eq(["policy linked.txt: deny"])
  end

  # A plain `rigor check` records no dependencies and keeps no session: its answer is the cold one.
  it "leaves a non-incremental warm run unchanged" do
    reader("charlie", 'policy("policy.txt")')
    store = Rigor::Cache::Store.new(root: cache_root)
    warm_run = lambda do
      guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: store,
                                              plugin_requirer: requirer)).diagnostics
    end
    warm_run.call
    write("policy.txt", "deny\n")
    expect(rows(warm_run.call)).to eq(rows(cold))
    expect(read_messages(warm_run.call)).to eq(["policy policy.txt: deny"])
  end
end
