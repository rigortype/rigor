# frozen_string_literal: true

# Issue #2515 — a receiverless call inside a class resolves to a top-level def when the class chain does not answer the
# name, and reads that def as written only when nothing else can answer it. The answer depends on the whole project's
# definitions of the name (`defines:<name>`), on the top-level def's own body (the `<toplevel>#name` site edge), and on
# the class chain (its ancestry edges). Without those reads an edit to a file the caller does not name leaves its
# served rows stale.
require "spec_helper"
require "tmpdir"

require "rigor/analysis/incremental_session"

RSpec.describe "incremental edges for a top-level def callee (#2515)", type: :runner do
  let(:use_source) do
    <<~RUBY
      class Host < Base
        def run
          opts = {}
          add_default(opts)
          puts(:set) if opts[:k]
        end
      end
    RUBY
  end
  let(:base_source) { "class Base\nend\n" }
  let(:reader) { "def add_default(h)\n  h.to_s\nend\n" }
  let(:writer) { "def add_default(h)\n  h[:k] = 1\nend\n" }
  let(:unrelated) { "def unrelated(h) = h.to_s\n" }
  let(:files) { { "use.rb" => use_source, "base.rb" => base_source, "defs.rb" => reader, "other.rb" => unrelated } }

  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), environment: shared_environment)
  end

  def rules_of(diagnostics) = diagnostics.map(&:rule).select { |rule| rule.start_with?("flow.") }.sort

  def full_rules(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    rules_of(guarded_run(runner).diagnostics)
  end

  # Writes `files` (name => source), analyses them, applies `edit` (name => source) and re-checks. Returns the recheck,
  # the incremental rules, the cold rules of the edited tree and the caller's path.
  def recheck_after(files, edit)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
      session = session_for(dir)
      expect(rules_of(guarded_baseline(session))).to eq(["flow.always-truthy-condition"])
      edit.each { |name, source| File.write(File.join(dir, name), source) }
      recheck = guarded_recheck(session)
      return [recheck, rules_of(recheck.diagnostics), full_rules(dir), File.join(dir, "use.rb")]
    end
  end

  def affected(recheck) = recheck.affected.map { |path| File.basename(path) }

  it "re-checks the caller when the top-level def's body starts writing" do
    recheck, incremental, cold, = recheck_after(files, "defs.rb" => writer)

    expect(affected(recheck)).to include("use.rb")
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when another file defines the name too" do
    recheck, incremental, cold, = recheck_after(files, "other.rb" => writer)

    expect(affected(recheck)).to include("use.rb")
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when the superclass starts defining the name" do
    recheck, incremental, cold, = recheck_after(files,
                                                "base.rb" => "class Base\n  def add_default(h) = h[:k] = 1\nend\n")

    expect(affected(recheck)).to include("use.rb")
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when Object is reopened with a def of the name" do
    reopening = "class Object\n  def add_default(h) = h[:k] = 1\nend\n"
    recheck, incremental, cold, = recheck_after(files, "other.rb" => reopening)

    expect(affected(recheck)).to include("use.rb")
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when the only edit prepends an already defined module to Object" do
    patch = "module Patch\n  def add_default(h) = h[:k] = 1\nend\n"
    recheck, incremental, cold, = recheck_after(files.merge("patch.rb" => patch),
                                                "other.rb" => "class Object\n  prepend Patch\nend\n")

    expect(affected(recheck)).to include("use.rb")
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when a file that already reopens Object starts prepending a module" do
    patch = "module Patch\n  def add_default(h) = h[:k] = 1\nend\n"
    recheck, incremental, cold, = recheck_after(files.merge("patch.rb" => patch, "obj.rb" => "class Object\nend\n"),
                                                "obj.rb" => "class Object\n  prepend Patch\nend\n")

    expect(affected(recheck)).to include("use.rb")
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when a file adds an alias of the name" do
    aliasing = "def other_writer(h) = h[:k] = 1\nalias add_default other_writer\n"
    recheck, incremental, cold, = recheck_after(files, "other.rb" => aliasing)

    expect(affected(recheck)).to include("use.rb")
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "does not re-check the caller when an unrelated top-level def appears" do
    recheck, incremental, cold, = recheck_after(files, "other.rb" => "#{unrelated}def zzz(h) = h[:k] = 1\n")

    expect(affected(recheck)).not_to include("use.rb")
    expect(incremental).to eq(["flow.always-truthy-condition"])
    expect(incremental).to eq(cold)
  end

  it "does not re-check the caller when an unrelated edit leaves the def's body alone" do
    recheck, incremental, cold, = recheck_after(files, "other.rb" => "#{unrelated}# a comment\n")

    expect(affected(recheck)).not_to include("use.rb")
    expect(incremental).to eq(["flow.always-truthy-condition"])
    expect(incremental).to eq(cold)
  end
end
