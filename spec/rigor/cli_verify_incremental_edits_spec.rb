# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# Issue #1967 — `--verify-incremental` re-analyses half of an unchanged tree, so it cannot see a missing invalidation
# edge: with nothing edited, every served row is still right. `--verify-incremental-edits N` replays edits on N
# sampled files through an editor buffer, never on disk (the file emptied, and the file reduced to its class/module
# skeleton), and compares each warm recheck with a full run of the edited tree.
#
# The global-census fixture is #2158's: `use.rb` writes `$stdout = 1`, which `other.rb`'s `def write` silences, and
# only the `global_census:` edge puts `use.rb` into the recheck once the `def` goes. The refinement fixture is #2163's:
# `x.rb` refines `Kernel#warn`, which makes `a.rb`'s self-call proof give up; reducing `x.rb` to `module R; end` keeps
# its declaration, so only the `refinement:` edge re-checks `a.rb`, and emptying it does not exercise that edge.
RSpec.describe Rigor::CLI do
  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.start(argv, out: out, err: err)

    [status, out.string, err.string]
  end

  around do |example|
    Dir.mktmpdir("rigor-verify-edits-") do |dir|
      Dir.chdir(File.realpath(dir)) do
        File.write(".rigor.yml", "paths:\n  - lib\n")
        FileUtils.mkdir_p("lib")
        example.run
      end
    end
  end

  def write_census_fixture
    File.write("lib/use.rb", "$stdout = 1\n")
    File.write("lib/other.rb", "class Other\n  def write(*) = nil\nend\n")
  end

  def write_refinement_fixture
    File.write("lib/a.rb", <<~RUBY)
      require "stringio"

      class Holder < Base
        def initialize = (@io = STDOUT)

        def dump
          return unless @io.is_a?(StringIO)

          log("dumping")
          @io.string
        end
      end
    RUBY
    File.write("lib/b.rb", "class Base\n  def log(message) = warn(message)\nend\n")
    File.write("lib/x.rb", "module R\n  refine Kernel do\n    def warn(*) = 1\n  end\nend\n")
  end

  def verify(*extra)
    run_cli("check", "--verify-incremental", "--no-stats", "--config", File.join(Dir.pwd, ".rigor.yml"), *extra)
  end

  # Removes one real edge: the analysis stops recording the `kind:` reads, as if the recording line were deleted.
  def drop_edge(kind)
    allow(Rigor::Analysis::DependencyRecorder).to receive(:read_name).and_wrap_original do |method, read_kind, *rest|
      method.call(read_kind, *rest) unless read_kind == kind
    end
  end

  # Wraps every session's {Rigor::Analysis::IncrementalSession#replay_edit} so its recheck passes through `transform`.
  def wrap_replay_edit(&transform)
    allow(Rigor::Analysis::IncrementalSession).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do |session|
        allow(session).to receive(:replay_edit).and_wrap_original do |method, *method_args|
          transform.call(method.call(*method_args))
        end
      end
    end
  end

  def without_use_rb(recheck)
    recheck&.with(diagnostics: recheck.diagnostics.reject { |row| row.path.end_with?("use.rb") })
  end

  describe "with the global-census fixture" do
    before { write_census_fixture }

    it "replays every edit of each sampled file and reports OK when every recheck matches a full run" do
      status, out, err = verify("--verify-incremental-edits", "2")

      expect(err).to eq("")
      expect(out).to include("--verify-incremental OK")
      # `use.rb` declares nothing, so it has no skeleton to replay: 2 edits of `other.rb`, 1 of `use.rb`.
      expect(out).to include("3 edits replayed (files emptied, reduced to their class/module skeleton, and with a " \
                             "body statement dropped), every recheck matches full")
      expect(status).to eq(0)
    end

    it "fails, naming the emptied file, when the global_census edge is not recorded" do
      drop_edge(:global_census)

      status, _out, err = verify("--verify-incremental-edits", "2")

      expect(err).to match(%r{FAILED — the recheck after emptying \S*lib/other\.rb differs from a full run\.})
      expect(err).to include("incremental-only: 0, full-only: 1")
      expect(status).to eq(1)
    end

    # A guard: without the option the gate replays nothing, so it passes over the missing edge.
    it "passes over the missing edge without the option" do
      drop_edge(:global_census)

      status, out, = verify

      expect(out).to include("--verify-incremental OK")
      expect(out).not_to include("edits replayed")
      expect(status).to eq(0)
    end

    it "fails when the recheck after an edit lists a full run's rows in another order" do
      File.write("lib/more.rb", "class More\n  def a = 1.zzz\n  def b = 2.yyy\nend\n")
      wrap_replay_edit { |recheck| recheck&.with(diagnostics: recheck.diagnostics.reverse) }

      status, _out, err = verify("--verify-incremental-edits", "3")

      expect(err).to match(/FAILED — the recheck after emptying \S+ differs from a full run\./)
      expect(err).to include("--verify-incremental FAILED — same set, different order.")
      expect(status).to eq(1)
    end

    it "fails when the recheck after an edit is missing a full run's row" do
      wrap_replay_edit { |recheck| without_use_rb(recheck) }

      status, _out, err = verify("--verify-incremental-edits", "2")

      expect(err).to match(%r{FAILED — the recheck after emptying \S*lib/other\.rb differs from a full run\.})
      expect(err).to include("incremental-only: 0, full-only: 1")
      expect(status).to eq(1)
    end

    it "fails when every replay declined, since nothing was compared" do
      wrap_replay_edit { nil }

      status, _out, err = verify("--verify-incremental-edits", "2")

      expect(err).to include("FAILED — every edit replay (3) declined")
      expect(status).to eq(1)
    end

    it "rejects a negative count" do
      status, _out, err = verify("--verify-incremental-edits", "-1")

      expect(err).to include("--verify-incremental-edits")
      expect(status).not_to eq(0)
    end
  end

  describe "with the refinement fixture" do
    before { write_refinement_fixture }

    it "reports OK when every edge is recorded" do
      status, out, err = verify("--verify-incremental-edits", "3")

      expect(err).to eq("")
      expect(out).to include("--verify-incremental OK")
      expect(status).to eq(0)
    end

    it "fails on the skeleton edit, which keeps the declaration, when the refinement edge is not recorded" do
      drop_edge(:refinement)

      status, _out, err = verify("--verify-incremental-edits", "3")

      expect(err).to match(%r{FAILED — the recheck after reducing to its class/module skeleton \S*lib/x\.rb differs})
      expect(status).to eq(1)
    end
  end

  # #2134's override shape: `vis.rb` reopens `Parent` only to make `foo` private, so `Child`'s private override reduces
  # nothing. With the `visibility:` reads dropped, emptying `vis.rb` already fails. The skeleton edit does not cover the
  # edge for #2161's `module_function` / `private` shape (see the self-extended fixture below).
  describe "with the method-visibility fixture" do
    before do
      File.write("lib/parent.rb", "class Parent\n  def foo = 1\nend\n")
      File.write("lib/child.rb", "class Child < Parent\n  private def foo = 2\nend\n")
      File.write("lib/vis.rb", "class Parent\n  private :foo\nend\n")
    end

    it "fails on the emptying edit when the visibility edge is not recorded" do
      drop_edge(:visibility)

      status, _out, err = verify("--verify-incremental-edits", "3")

      expect(err).to match(%r{FAILED — the recheck after emptying \S*lib/vis\.rb differs from a full run\.})
      expect(status).to eq(1)
    end

    # A guard for the fixture: with the edge recorded every replay matches.
    it "reports OK when every edge is recorded" do
      status, out, = verify("--verify-incremental-edits", "3")

      expect(out).to include("--verify-incremental OK")
      expect(status).to eq(0)
    end
  end

  # #2161's shape, #2277's gap: `Es` extends itself and `two` is private, so `Es.two(1)` is a private call, unless a
  # reopening's `module_function :two` row gives it a public singleton copy (then the call is an arity error).
  # `vis.rb` also defines `helper`, so emptying it or reducing it to `module Es; end` removes a definition and moves a
  # broader key; only dropping the `module_function :two` statement leaves `private :two` behind (the issue's swap)
  # with the declarations and defs as they were, so the `visibility:` read of `DefinerResolution.module_function_row?`
  # is the edge that re-checks `use.rb`.
  describe "with the self-extended module_function fixture" do
    before do
      File.write("lib/es.rb", "module Es\n  extend self\n  private def two(a, b) = a\nend\n")
      File.write("lib/use.rb", "def b = Es.two(1)\n")
      File.write("lib/vis.rb", "module Es\n  def helper = 1\n  module_function :two\n  private :two\nend\n")
    end

    it "reports OK when every edge is recorded" do
      status, out, err = verify("--verify-incremental-edits", "3")

      expect(err).to eq("")
      expect(out).to include("--verify-incremental OK")
      expect(status).to eq(0)
    end

    it "fails on the statement-dropping edit, which keeps every definition, when no visibility edge is recorded" do
      drop_edge(:visibility)

      status, _out, err = verify("--verify-incremental-edits", "3")

      expect(err).to match(%r{FAILED — the recheck after dropping the statement at line 3 of \S*lib/vis\.rb differs})
      expect(status).to eq(1)
    end
  end
end
