# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #1641. A reader whose resolution chain holds an EXTERNAL module (`Comparable`) declines `call.wrong-arity` once a
# project file gives that module a hook (`def self.included(base) = base.prepend(P)`): the hook may prepend a
# definer ahead of the answer. The external entry filed only the sites of the names it can denote, so a NEW file
# declaring the hook re-checked nothing and the warm run kept the diagnostic the cold run declines. The chain now
# files a negative method edge per hook name on the module's singleton side (`method:Comparable.included`); a file
# adding a non-hook method does not touch it. A negative class edge on `Comparable` would, and would re-check every
# reader of `Kernel` or `Enumerable` on any reopening: the last example fails under it. The oracle is a full
# `--no-cache` run of the same tree; the driver is `IncrementalSession`.
RSpec.describe "external chain entry hooks — incremental" do
  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                            environment: shared_environment)
  end

  def arity(list)
    list.select { |d| d.rule == "call.wrong-arity" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    arity(guarded_run(runner).diagnostics)
  end

  let(:hook) do
    "module P\n  def foo(*) = 1\nend\n\nmodule Comparable\n  def self.included(base) = base.prepend(P)\nend\n"
  end
  let(:plain) { "module P\n  def foo(*) = 1\nend\n\nmodule Comparable\n  def self.helper = 1\nend\n" }

  let(:root_answers) do
    { "a.rb" => "class C\n  include Comparable\n\n  def foo(x) = x\nend\n", "b.rb" => "C.new.foo\n" }
  end

  let(:base_answers) do
    {
      "base.rb" => "class Base\n  include Comparable\n\n  def foo(x) = x\nend\n",
      "c.rb" => "class C < Base\nend\n",
      "b.rb" => "C.new.foo\n"
    }
  end

  # Writes `files`, takes the baseline (which fires), then applies each step in turn — a Hash of writes, `nil`
  # contents deleting the file — and yields `[warm, cold, recheck]` after each recheck.
  def walk(files, steps)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
      session = session_for(dir)
      expect(arity(guarded_baseline(session))).to eq([["b.rb", 1]])
      steps.each do |edits|
        edits.each do |name, source|
          path = File.join(dir, name)
          source.nil? ? File.delete(path) : File.write(path, source)
        end
        recheck = guarded_recheck(session)
        yield arity(recheck.diagnostics), full_run(dir), recheck, dir
      end
    end
  end

  it "re-checks a root-answered reader when a new file gives the external module a hook" do
    walk(root_answers, [{ "x.rb" => hook }]) do |warm, cold|
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end
  end

  it "re-checks a reader answered by its superclass when a new file gives the external module a hook" do
    walk(base_answers, [{ "x.rb" => hook }]) do |warm, cold|
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end
  end

  it "keeps warm equal to cold when the hook file is later edited and then removed" do
    colds = []
    walk(root_answers, [{ "x.rb" => hook }, { "x.rb" => plain }, { "x.rb" => hook }, { "x.rb" => nil }]) do |warm, cold|
      colds << cold
      expect(warm).to eq(cold)
    end
    expect(colds).to eq([[], [["b.rb", 1]], [], [["b.rb", 1]]])
  end

  it "serves the reader from the cache when a new file adds only a non-hook method to the external module" do
    walk(root_answers, [{ "x.rb" => plain }]) do |warm, cold, recheck, dir|
      expect(cold).to eq([["b.rb", 1]])
      expect(warm).to eq(cold)
      expect(recheck.affected).to include(File.join(dir, "x.rb"))
      expect(recheck.affected).not_to include(File.join(dir, "b.rb"))
    end
  end
end
