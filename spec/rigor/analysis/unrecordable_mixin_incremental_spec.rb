# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1661 — a file that taints a module with a mixin the tables cannot position (an entry of
# `Scope::DiscoveryIndex#unpositioned_mixins`, `"*"` or a named edge) makes an arity reader of a chain through that
# module decline. When the module is external (RBS-known, declared by no project file), the reader's chain edges name
# no declaring file, so before the `mixin:<qualified name>` edge on external entries a warm recheck kept the reader's
# old report. The oracle is a full `--no-cache` run of the same tree, as in `class_mark_incremental_spec.rb`.
RSpec.describe "unrecordable mixins — incremental" do
  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                            environment: shared_environment)
  end

  def diagnostics(list)
    list.select { |d| d.rule == "call.wrong-arity" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    diagnostics(guarded_run(runner).diagnostics)
  end

  # `edits` maps a file name to its new source, or to nil to delete it. Returns the baseline, the warm recheck's
  # diagnostics, the cold run's, and the basenames the recheck re-analyzed as dependents.
  def warm_and_cold(files, edits)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
      session = session_for(dir)
      baseline = diagnostics(guarded_baseline(session))
      edits.each do |name, source|
        path = File.join(dir, name)
        source.nil? ? File.delete(path) : File.write(path, source)
      end
      recheck = guarded_recheck(session)
      affected = recheck.affected.map { |path| File.basename(path) }.sort
      [baseline, diagnostics(recheck.diagnostics), full_run(dir), affected]
    end
  end

  def base_files(mod)
    files = { "a.rb" => "class C\n  include #{mod}\n  def foo(x) = x\nend\n", "b.rb" => "C.new.foo\n",
              "p.rb" => "module P; end\nmodule Q; def foo = 1; end\n" }
    files["m.rb"] = "module #{mod}; end\n" unless mod == "Comparable"
    files
  end

  def reported = [["b.rb", 1]]

  # The two directions that drop the taint are guards on the external module too: they pass without the `mixin:`
  # edge, since the reader last ran with the tainting file in the tree and its chain edges already reach that file.
  shared_examples "a tainting file" do
    it "re-checks the reader when the file appears" do
      baseline, warm, cold = warm_and_cold(base_files(mod), "x.rb" => taint)

      expect(baseline).to eq(reported)
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end

    it "re-checks the reader when the file goes" do
      baseline, warm, cold = warm_and_cold(base_files(mod).merge("x.rb" => taint), "x.rb" => nil)

      expect(baseline).to eq([])
      expect(cold).to eq(reported)
      expect(warm).to eq(cold)
    end

    it "re-checks the reader when an edit adds the taint to a file that names no module" do
      baseline, warm, cold = warm_and_cold(base_files(mod).merge("x.rb" => "X = 1\n"), "x.rb" => taint)

      expect(baseline).to eq(reported)
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end

    it "re-checks the reader when an edit drops the taint" do
      baseline, warm, cold = warm_and_cold(base_files(mod).merge("x.rb" => taint), "x.rb" => "X = 1\n")

      expect(baseline).to eq([])
      expect(cold).to eq(reported)
      expect(warm).to eq(cold)
    end
  end

  {
    "a splatted include" => ->(mod) { "MODS = [P]\nmodule #{mod}; include(*MODS); end\n" },
    "an include of a method call" => ->(mod) { "module #{mod}; def self.pick = P; include(pick); end\n" },
    "a conditional receiver-form include" => ->(mod) { "x = P\n#{mod}.include(x) if ENV[\"X\"]\n" },
    "an include inside a loop" => ->(mod) { "module #{mod}; [P].each { |m| include m }; end\n" },
    "an include sent by name" => ->(mod) { "module #{mod}; send(:include, P); end\n" },
    "an instance included hook" => ->(mod) { "module #{mod}; def included(base) = base.prepend(P); end\n" },
    # A named edge in a block, unpositioned but no `"*"`, in a file that declares nothing: it moves no envelope mark,
    # so only the `mixin:` key re-checks the reader.
    "an include in a class_eval block" => ->(mod) { "#{mod}.class_eval { include Q }\n" }
  }.each do |form, source|
    describe "#{form} on an external module" do
      let(:mod) { "Comparable" }
      let(:taint) { source.call(mod) }

      it_behaves_like "a tainting file"
    end

    # Guard: a project module's reader already files the module's sites and its `class:` edge.
    describe "#{form} on a project module" do
      let(:mod) { "M" }
      let(:taint) { source.call(mod) }

      it_behaves_like "a tainting file"
    end
  end

  # The key is the qualified name: a taint on a project `Foo::Constants` re-checks no reader of a chain through the
  # RBS-known `File::Constants`, and a taint on `File::Constants` itself still does.
  describe "a qualified external module" do
    let(:files) do
      { "a.rb" => "class C\n  include File::Constants\n  def foo(x) = x\nend\n", "b.rb" => "C.new.foo\n",
        "p.rb" => "module P; end\n" }
    end

    it "re-checks no reader when the taint lands on another module of the same last segment" do
      baseline, warm, cold, affected =
        warm_and_cold(files, "x.rb" => "module Foo; module Constants; end; end\nFoo::Constants.include(yext)\n")

      expect(baseline).to eq(reported)
      expect(warm).to eq(cold)
      expect(affected).not_to include("b.rb")
    end

    it "re-checks the reader when the taint lands on the module itself" do
      baseline, warm, cold = warm_and_cold(files, "x.rb" => "x = P\nFile::Constants.include(x) if ENV[\"X\"]\n")

      expect(baseline).to eq(reported)
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end
  end

  # The unpositioned table keys a receiver-form owner by the spelling written (`Constants` inside `class File`), while
  # the chain files the qualified candidate, so the owner also fires every recorded key ending in `::Constants`.
  {
    "File::Constants" => "class File; Constants.include(*MODS); end\n",
    "IO::WaitReadable" => "class IO; WaitReadable.include(*MODS); end\n"
  }.each do |qualified, taint|
    describe "a relative spelling of #{qualified} in its reopened namespace" do
      let(:files) do
        { "a.rb" => "class C\n  include #{qualified}\n  def foo(x) = x\nend\n", "b.rb" => "C.new.foo\n",
          "p.rb" => "module P; end\nMODS = [P]\n" }
      end

      it "re-checks the reader when the file appears" do
        baseline, warm, cold = warm_and_cold(files, "x.rb" => taint)

        expect(baseline).to eq(reported)
        expect(cold).to eq([])
        expect(warm).to eq(cold)
      end

      it "re-checks the reader when an edit adds the taint to a file that names no module" do
        baseline, warm, cold = warm_and_cold(files.merge("x.rb" => "X = 1\n"), "x.rb" => taint)

        expect(baseline).to eq(reported)
        expect(cold).to eq([])
        expect(warm).to eq(cold)
      end
    end
  end

  # Guard (of the key choice): the external entry's edge is the module's unpositioned-mixin set, not `mark:` or a class
  # edge, so a file reopening `Comparable` with an ordinary method re-checks no reader of a chain through it.
  it "re-checks no reader when a new file reopens the external module without a taint" do
    baseline, warm, cold, affected = warm_and_cold(base_files("Comparable"),
                                                   "x.rb" => "module Comparable; def zz = 1; end\n")

    expect(baseline).to eq(reported)
    expect(warm).to eq(cold)
    expect(affected).not_to include("b.rb")
  end
end
