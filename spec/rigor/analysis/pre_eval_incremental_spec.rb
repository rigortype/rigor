# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #1585 / #1554 — the snapshot's global fingerprint must move when an input the analysis reads changes but no
# analysed file does. Two such inputs: the contents of a `pre_eval:` file outside the analysed paths (#1585), and
# an auto-detected `sig/*.rbs` that `signature_paths:` (nil) does not list (#1554). A warm `--incremental` run
# that keeps the old snapshot replays the diagnostics computed before the edit.
#
# The oracle is a cold, cache-less run of the same tree; the driver is a fresh `IncrementalSession` per process,
# as in `incremental_session_spec.rb` (`#run_incremental`, cross-process persistence).
RSpec.describe "pre_eval and auto-detected sig — incremental fingerprint" do
  def undefined_method(list)
    list.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def cold_run(config)
    runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
    undefined_method(guarded_run(runner).diagnostics)
  end

  def fingerprint(config, roots)
    Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: roots)
  end

  # One `rigor check --incremental` process: a brand-new session reading the snapshot under `fp`.
  def process_run(config, roots, snapshot:, fp:)
    session = Rigor::Analysis::IncrementalSession.new(configuration: config, paths: roots)
    diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot, fingerprint: fp)
    [undefined_method(diagnostics), warm]
  end

  describe "a pre_eval: file outside the analysed paths (#1585)" do
    it "re-checks when the pre_eval file changes, matching a cold run; an unchanged run stays warm" do
      Dir.mktmpdir do |tmp|
        lib = File.join(tmp, "lib")
        support = File.join(tmp, "support")
        Dir.mkdir(lib)
        Dir.mkdir(support)
        pre = File.join(support, "pre.rb")
        File.write(File.join(lib, "a.rb"), %("a".shout\n))
        File.write(pre, "class String; def shout = upcase; end\n")

        config = Rigor::Configuration.new("paths" => [lib], "pre_eval" => [pre])
        snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(tmp, ".cache"))
        fp = fingerprint(config, [lib])

        # Process 1 — cold. `shout` is defined by the pre_eval file, so nothing is undefined.
        diags1, warm1 = process_run(config, [lib], snapshot: snapshot, fp: fp)
        expect(warm1).to be(false)
        expect(diags1).to eq([])

        # Process 2 — nothing changed: the fingerprint is stable and the snapshot is reused.
        diags2, warm2 = process_run(config, [lib], snapshot: snapshot, fp: fingerprint(config, [lib]))
        expect(warm2).to be(true)
        expect(diags2).to eq([])

        # The pre_eval file is edited (outside the analysed paths; a.rb is untouched). `shout` is renamed.
        File.write(pre, "class String; def yell = upcase; end\n")
        fp_after = fingerprint(config, [lib])
        expect(fp_after).not_to eq(fp)

        # Process 3 — the edited pre_eval file must invalidate the snapshot: the warm result equals a cold run.
        diags3, _warm3 = process_run(config, [lib], snapshot: snapshot, fp: fp_after)
        expect(diags3).to eq(cold_run(config))
        expect(diags3).to eq([["a.rb", 1]])
      end
    end
  end

  describe "an auto-detected sig/ directory (#1554)" do
    it "re-checks when the auto-detected sig/*.rbs changes, matching a cold run" do
      Dir.mktmpdir do |tmp|
        Dir.chdir(tmp) do
          Dir.mkdir("lib")
          Dir.mkdir("sig")
          File.write("lib/a.rb", "class Foo\n  def bar = 1\nend\n\nFoo.new.bar.upcase\n")
          sig = File.join(tmp, "sig", "foo.rbs")
          File.write(sig, "class Foo\n  def bar: () -> Integer\nend\n")

          # No `signature_paths:` — `sig/` is auto-detected by the environment, not configured.
          config = Rigor::Configuration.new("paths" => ["lib"])
          snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(tmp, ".cache"))
          fp = fingerprint(config, ["lib"])

          # Process 1 — cold. `Integer#upcase` does not exist, so the sig's return type is reported.
          diags1, warm1 = process_run(config, ["lib"], snapshot: snapshot, fp: fp)
          expect(warm1).to be(false)
          expect(diags1).to eq([["a.rb", 5]])

          # The sig's return type is edited to String; lib/a.rb is untouched.
          File.write(sig, "class Foo\n  def bar: () -> String\nend\n")
          fp_after = fingerprint(config, ["lib"])
          expect(fp_after).not_to eq(fp)

          # Process 2 — the warm result must equal a cold run (the diagnostic goes away).
          diags2, _warm2 = process_run(config, ["lib"], snapshot: snapshot, fp: fp_after)
          expect(diags2).to eq(cold_run(config))
          expect(diags2).to eq([])
        end
      end
    end
  end
end
