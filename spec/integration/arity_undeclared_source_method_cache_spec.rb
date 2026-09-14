# frozen_string_literal: true

# Issue #992 — the envelope table is a new input to whole-project discovery, and a new input wired only
# through the in-process path never runs on a cached (default) run (#610 / #696). Every arm here runs through
# a real `Cache::Store`, and judges a warm answer against a cold one.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/incremental_session"
require "rigor/cache/store"
require "rigor/cache/incremental_snapshot"
require "rigor/configuration"

RSpec.describe "call.wrong-arity on an undeclared source method through the caches (#992)" do
  around do |example|
    Dir.mktmpdir("rigor-arity-undeclared-cache-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:paths) { %w[lib/a.rb lib/use.rb lib/wrap.rb] }
  let(:firing) { [["lib/use.rb", 1, "wrong number of arguments to `f' on A (given 2, expected 1)"]] }

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def write_project(wrap: "")
    write("lib/a.rb", "class A\n  def f(a) = a\nend\n")
    write("lib/use.rb", "A.new.f(1, 2)\n")
    write("lib/wrap.rb", "class A\n#{wrap}end\n")
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
  end

  def arity_rows(diagnostics)
    diagnostics.select { |d| d.rule == "call.wrong-arity" }.map { |d| [d.path, d.line, d.message] }.sort
  end

  def full_run(cache_store)
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: cache_store)
    guarded_run(runner, paths).diagnostics
  end

  it "reports the same firing warm as cold through a real Cache::Store" do
    write_project
    root = File.join(Dir.pwd, ".rigor", "cache")

    cold = arity_rows(full_run(Rigor::Cache::Store.new(root: root)))
    warm = arity_rows(full_run(Rigor::Cache::Store.new(root: root)))

    expect(cold).to eq(firing)
    expect(warm).to eq(cold)
    expect(arity_rows(full_run(nil))).to eq(cold)
  end

  it "withdraws the firing on the warm run after another file wraps the method" do
    write_project
    root = File.join(Dir.pwd, ".rigor", "cache")
    expect(arity_rows(full_run(Rigor::Cache::Store.new(root: root)))).to eq(firing)

    write_project(wrap: "  memoize :f\n")
    expect(arity_rows(full_run(Rigor::Cache::Store.new(root: root)))).to eq([])
    expect(arity_rows(full_run(nil))).to eq([])
  end

  # ADR-85 WD2 — a bundle-served file must fold the envelopes its live walk records, and a changed file's
  # envelope contribution must reach both the fold and the declaration signature that decides whether its
  # dependents re-check.
  describe "the ADR-85 seed bundle and the incremental recheck" do
    it "folds the same envelope table from cached bundles as from a cold walk" do
      write_project(wrap: "  def f(a, b) = a\n")
      cold = Rigor::Inference::ScopeIndexer.discovered_project_index_incremental(paths, seed_bundles: {})
      bundles = Marshal.load(Marshal.dump(cold.fetch(:bundles)))
      warm = Rigor::Inference::ScopeIndexer.discovered_project_index_incremental(paths, seed_bundles: bundles)

      envelopes = cold.fetch(:def_index).fetch(:parameter_envelopes)
      expect(envelopes.fetch("A").fetch(%i[instance f])).to eq(Rigor::Source::ParameterEnvelope::OPAQUE)
      expect(warm.fetch(:def_index).fetch(:parameter_envelopes)).to eq(envelopes)
    end

    it "moves a file's declaration signature when only a name-wrapping macro is added to it" do
      write_project
      before = Rigor::Inference::ScopeIndexer.scan_summary_for_paths(["lib/wrap.rb"])
      write_project(wrap: "  memoize :f\n")
      after = Rigor::Inference::ScopeIndexer.scan_summary_for_paths(["lib/wrap.rb"])

      expect(after[:declaration_signatures]["lib/wrap.rb"]).not_to eq(before[:declaration_signatures]["lib/wrap.rb"])
    end

    def session(store)
      Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: paths, cache_store: store)
    end

    def incremental_rows
      root = File.join(Dir.pwd, ".rigor", "cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)
      diagnostics, warm = guarded_run_incremental(session(Rigor::Cache::Store.new(root: root)),
                                                  snapshot: snapshot, fingerprint: fingerprint)
      [arity_rows(diagnostics), warm]
    end

    # A call that fits records no file-level class edge (the bucket reads are withheld), so the two ways a
    # fitting call can start firing must each reach it some other way.
    it "re-checks a fitting caller when the owner def narrows (its symbol edge)" do
      write("lib/a.rb", "class A\n  def f(a, b = 1) = a\nend\n")
      write("lib/use.rb", "A.new.f(1, 2)\n")
      write("lib/wrap.rb", "class Unrelated\nend\n")
      expect(incremental_rows).to eq([[], false])

      write("lib/a.rb", "class A\n  def f(a) = a\nend\n")
      expect(incremental_rows).to eq([firing, true])
    end

    it "re-checks a fitting caller when a nearer level gains a def (its negative edge)" do
      write("lib/a.rb", "class A\n  def f(a, b) = a\nend\n")
      write("lib/use.rb", "B.new.f(1, 2)\n")
      write("lib/wrap.rb", "class B < A\nend\n")
      expect(incremental_rows).to eq([[], false])

      write("lib/wrap.rb", "class B < A\n  def f(a) = a\nend\n")
      expect(incremental_rows)
        .to eq([[["lib/use.rb", 1, "wrong number of arguments to `f' on B (given 2, expected 1)"]], true])
    end

    # The project's own `sig/` declares `A` without `f`, so the typer dispatches `A.new.f` through RBS and
    # records no edge to the file that defines `f`: the rule's own replayed walk is the only one.
    it "re-checks a caller on a sig/-declared class when another file wraps the method" do
      write("sig/a.rbs", "class A\nend\n")
      write_project
      sig_config = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0, "signature_paths" => %w[sig])
      )
      allow(self).to receive(:configuration).and_return(sig_config)
      expect(incremental_rows).to eq([firing, false])

      write_project(wrap: "  memoize :f\n")
      expect(incremental_rows).to eq([[], true])
    end

    it "re-checks the caller when another file wraps the method, matching a full run" do
      write_project
      root = File.join(Dir.pwd, ".rigor", "cache")
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: root)
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: paths)

      first, warm_first = guarded_run_incremental(session(Rigor::Cache::Store.new(root: root)),
                                                  snapshot: snapshot, fingerprint: fingerprint)
      expect(warm_first).to be(false)
      expect(arity_rows(first)).to eq(firing)

      write_project(wrap: "  memoize :f\n")
      second, warm_second = guarded_run_incremental(session(Rigor::Cache::Store.new(root: root)),
                                                    snapshot: snapshot, fingerprint: fingerprint)
      expect(warm_second).to be(true)
      expect(arity_rows(second)).to eq([])
      expect(arity_rows(second)).to eq(arity_rows(full_run(nil)))
    end
  end
end
