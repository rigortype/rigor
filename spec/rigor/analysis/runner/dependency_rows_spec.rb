# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Plain data in, rows out: `Runner::DependencyRows` reads no `Runner` state, so each example hands an entry the
# values the runner would (a path list, a buffer binding, a plugin list) and compares the rows. The runner's own specs
# pin the same rows through a whole run; the examples here pin one input at a time, which is the cache's soundness
# question: a row that ignores an input it should see serves a stale answer, and a row that sees one it should not
# costs the warm run its hit.
RSpec.describe Rigor::Analysis::Runner::DependencyRows do
  let(:entry) { Rigor::Cache::Descriptor::FileEntry }
  let(:glob_entry) { Rigor::Cache::Descriptor::GlobEntry }
  let(:buffer) { Struct.new(:mapping) { def resolve(path) = mapping.fetch(path, path) } }

  let(:dir) { File.realpath(Dir.mktmpdir("rigor-dependency-rows")) }

  after { FileUtils.remove_entry(dir) }

  def write(name, body = "x = 1\n")
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  describe ".analyzed_file_entries" do
    it "records one `:stat` row per analysed file, in expansion order" do
      a = write("a.rb")
      b = write("b.rb")

      rows = described_class.analyzed_file_entries({ files: [b, a] }, nil)

      expect(rows.map(&:path)).to eq([b, a])
      expect(rows.map(&:comparator).uniq).to eq([:stat])
    end

    it "goes stale when a file's bytes move" do
      a = write("a.rb")
      rows = Rigor::Cache::Descriptor.new(files: described_class.analyzed_file_entries({ files: [a] }, nil))
      File.write(a, "x = 2222222\n")

      expect(rows.fresh?).to be(false)
    end

    it "stays fresh for the same bytes read again" do
      a = write("a.rb")
      rows = Rigor::Cache::Descriptor.new(files: described_class.analyzed_file_entries({ files: [a] }, nil))

      expect(rows.fresh?).to be(true)
    end

    it "reads the buffer's physical file for a path the buffer binds" do
      logical = File.join(dir, "logical.rb")
      physical = write("physical.rb")
      binding = buffer.new({ logical => physical })

      expect(described_class.analyzed_file_entries({ files: [logical] }, binding).map(&:path)).to eq([physical])
    end
  end

  describe ".discovery_file_entries" do
    it "is empty when the run did not widen its discovery" do
      a = write("a.rb")

      expect(described_class.discovery_file_entries({ files: [a] }, nil, nil)).to eq([])
    end

    it "records only the discovered files the run did not analyse" do
      a = write("a.rb")
      b = write("b.rb")

      rows = described_class.discovery_file_entries({ files: [a] }, { files: [a, b] }, nil)

      expect(rows.map(&:path)).to eq([b])
    end
  end

  describe ".pre_eval_file_entries" do
    it "records a `:stat` row per `pre_eval:` file that exists and skips one that does not" do
      present = write("core_ext.rb")

      rows = described_class.pre_eval_file_entries([present, File.join(dir, "gone.rb")], nil)

      expect(rows.map(&:path)).to eq([present])
      expect(rows.first.comparator).to eq(:stat)
    end

    it "digests the buffer's physical file" do
      logical = File.join(dir, "logical.rb")
      physical = write("physical.rb")

      rows = described_class.pre_eval_file_entries([logical], buffer.new({ logical => physical }))

      expect(rows.map(&:path)).to eq([physical])
    end
  end

  describe ".template_unit_file_entries" do
    let(:units) do
      Struct.new(:source_paths) do
        def physical_path(path, binding) = binding ? binding.resolve(path) : path
      end
    end

    it "records a `:stat` row per template the run read, and none for one with no file behind it" do
      template = write("view.erb", "<%= 1 %>")

      rows = described_class.template_unit_file_entries(units.new([template, File.join(dir, "gone.erb")]), nil)

      expect(rows.map(&:path)).to eq([template])
    end

    it "asks the units for the buffer-bound path" do
      logical = File.join(dir, "view.erb")
      physical = write("bound.erb")

      rows = described_class.template_unit_file_entries(units.new([logical]), buffer.new({ logical => physical }))

      expect(rows.map(&:path)).to eq([physical])
    end
  end

  describe ".root_presence_entries" do
    it "records a `:kind` row per analysis root, `pre_eval:` entry and signature root, each path once" do
      root = File.join(dir, "lib")
      FileUtils.mkdir_p(root)
      file = write("core_ext.rb")
      sig = File.join(dir, "sig")

      rows = described_class.root_presence_entries([root, root], [file], [sig])

      expect(rows.map { |row| [row.path, row.value] }).to eq(
        [[root, "directory"], [file, "file"], [sig, "absent"]]
      )
      expect(rows.map(&:comparator).uniq).to eq([:kind])
    end

    it "moves when a root turns from a directory into a file" do
      root = File.join(dir, "lib")
      FileUtils.mkdir_p(root)
      before = described_class.root_presence_entries([root], [], [])
      FileUtils.rm_rf(root)
      File.write(root, "")

      expect(described_class.root_presence_entries([root], [], [])).not_to eq(before)
    end
  end

  describe ".kind_entries" do
    it "records one `:kind` row per distinct path" do
      file = write("a.rb")

      rows = described_class.kind_entries([file, file, File.join(dir, "none")], nil)

      expect(rows.map(&:value)).to eq(%w[file absent])
    end

    it "reads the buffer's physical path" do
      logical = File.join(dir, "logical.rb")
      physical = write("physical.rb")

      rows = described_class.kind_entries([logical], buffer.new({ logical => physical }))

      expect(rows.map(&:path)).to eq([physical])
    end
  end

  describe ".unanalysed_pre_eval_entries" do
    it "leaves out a `pre_eval:` file the run analyses, and records a `:stat` row for one it does not" do
      analysed = write("a.rb")
      outside = write("core_ext.rb")

      rows = described_class.unanalysed_pre_eval_entries([analysed], [analysed, outside], nil)

      expect(rows.map { |row| [row.path, row.comparator] }).to eq([[outside, :stat]])
    end

    it "records a `:kind` row for an entry that is not a file" do
      missing = File.join(dir, "missing.rb")

      rows = described_class.unanalysed_pre_eval_entries([], [missing], nil)

      expect(rows.map { |row| [row.path, row.comparator, row.value] }).to eq([[missing, :kind, "absent"]])
    end

    it "compares absolute spellings, so `./a.rb` and `a.rb` name one file" do
      write("a.rb")
      Dir.chdir(dir) do
        expect(described_class.unanalysed_pre_eval_entries(["./a.rb"], ["a.rb"], nil)).to eq([])
      end
    end
  end

  describe ".discovery_glob_entries" do
    it "is empty unless the run widened its discovery" do
      expect(described_class.discovery_glob_entries(false, [dir])).to eq([])
    end

    it "records one names-mode row per configured path that is a directory, and it moves when a file appears" do
      write("lib/a.rb")
      root = File.join(dir, "lib")
      before = described_class.discovery_glob_entries(true, [root, File.join(dir, "missing")])
      write("lib/b.rb")
      after = described_class.discovery_glob_entries(true, [root, File.join(dir, "missing")])

      expect(before.map { |row| [row.root, row.pattern, row.mode] })
        .to eq([[root, Rigor::Analysis::PathExpansion::RUBY_GLOB, :names]])
      expect(after).not_to eq(before)
    end

    it "does not move when a file under the root is edited" do
      a = write("lib/a.rb")
      root = File.join(dir, "lib")
      before = described_class.discovery_glob_entries(true, [root])
      File.write(a, "x = 22222222\n")

      expect(described_class.discovery_glob_entries(true, [root])).to eq(before)
    end
  end

  describe ".bundle_sig_glob_entries" do
    it "is empty when no bundle path resolves" do
      expect(described_class.bundle_sig_glob_entries(nil, false)).to eq([])
    end

    it "records one names-mode row per bundle `sig/` layout under a configured bundle path" do
      write("bundle/ruby/4.0.0/gems/foo-1.0/sig/foo.rbs", "")
      bundle = File.join(dir, "bundle")

      rows = described_class.bundle_sig_glob_entries(bundle, false)

      expect(rows.map(&:pattern)).to eq(Rigor::Environment::BundleSigDiscovery::SIG_GLOBS)
      expect(rows.map(&:mode).uniq).to eq([:names])
    end
  end

  describe ".signature_rows" do
    it "splits the files under the project's own roots from the rest" do
      own = File.join(dir, "sig")
      other = File.join(dir, "elsewhere")
      write("sig/own.rbs", "class Own\nend\n")
      write("elsewhere/other.rbs", "class Other\nend\n")

      own_rows, other_rows = described_class.signature_rows([Pathname(own), Pathname(other)], nil, [own])

      expect(own_rows.files.map(&:path).uniq).to eq([File.join(own, "own.rbs")])
      expect(other_rows.files.map(&:path)).to include(File.join(other, "other.rbs"))
      expect(other_rows.files.map(&:path)).not_to include(File.join(own, "own.rbs"))
    end

    it "counts the selected core root as the project's own" do
      core = File.join(dir, "core")
      write("core/core.rbs", "class Core\nend\n")

      own_rows, other_rows = described_class.signature_rows([Pathname(core)], core, [])

      expect(own_rows.files.map(&:path).uniq).to eq([File.join(core, "core.rbs")])
      expect(other_rows.files.map(&:path)).not_to include(File.join(core, "core.rbs"))
    end
  end

  describe ".plugin_boundary_rows" do
    let(:boundary_class) do
      Struct.new(:cache_descriptor)
    end

    def plugin_with(boundary)
      plugin = Object.new
      plugin.instance_variable_set(:@io_boundary, boundary) unless boundary.nil?
      plugin
    end

    it "concatenates the rows of every plugin that built a boundary and skips one that never did" do
      read = entry.stat(path: write("a.rb"), digest: "d")
      listed = glob_entry.compute(root: dir, pattern: "*.rb", mode: :names)
      descriptor = Rigor::Cache::Descriptor.new(files: [read], globs: [listed])

      rows = described_class.plugin_boundary_rows([plugin_with(nil), plugin_with(boundary_class.new(descriptor))])

      expect(rows.files).to eq([read])
      expect(rows.globs).to eq([listed])
    end

    it "does not build a boundary on a plugin that has none" do
      plugin = plugin_with(nil)

      described_class.plugin_boundary_rows([plugin])

      expect(plugin.instance_variable_defined?(:@io_boundary)).to be(false)
    end
  end

  describe ".producer_watch_glob_entries" do
    it "asks each plugin for the glob rows of every producer that declares a `watch:`" do
      klass = Class.new do
        def self.producers = { watched: { watch: ["*.yml"] }, plain: {} }
        def watch_glob_entries(patterns) = patterns.map { |pattern| [:row, pattern] }
      end

      expect(described_class.producer_watch_glob_entries([klass.new])).to eq([[:row, "*.yml"]])
    end
  end

  describe ".analysis_reads_attributed?" do
    let(:read) { entry.stat(path: "/a", digest: "d") }
    let(:pre) { Rigor::Cache::Descriptor.new }

    it "is true when every row that appeared is one some file's analysis was credited with" do
      post = Rigor::Cache::Descriptor.new(files: [read])

      expect(described_class.analysis_reads_attributed?(post, pre, { "a.rb" => [read] })).to be(true)
    end

    it "is false when a row appeared that no file's analysis was credited with" do
      post = Rigor::Cache::Descriptor.new(files: [read])

      expect(described_class.analysis_reads_attributed?(post, pre, { "a.rb" => [] })).to be(false)
    end

    it "is false for an unattributed listing row" do
      listed = glob_entry.compute(root: dir, pattern: "*.rb", mode: :names)
      post = Rigor::Cache::Descriptor.new(globs: [listed])

      expect(described_class.analysis_reads_attributed?(post, pre, {})).to be(false)
    end

    it "ignores a row that was already there before the per-file loop" do
      post = Rigor::Cache::Descriptor.new(files: [read])

      expect(described_class.analysis_reads_attributed?(post, post, {})).to be(true)
    end
  end

  it "keeps the helper behind `signature_rows` private" do
    expect(described_class).not_to respond_to(:within?)
  end
end
