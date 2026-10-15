# frozen_string_literal: true

# Issues #1962 and #1555 — the plain ADR-45 run-result slot recorded no row for a path whose mere presence the
# answer depends on. An analysis root that appeared, vanished or changed kind while the analysed file set stayed
# the same kept the slot fresh, so a warm run served the old path-error row (and, under `--fail-on=warning`, the
# old exit code, which is the rows' highest severity). A signature root or a `pre_eval:` entry that did not
# exist when the slot was written had no row at all, so creating it left the old diagnostics served.
#
# Both readers are exercised against a real `Cache::Store`: the runner's read-through slot, which writes the
# rows, and the engine-free {RunCacheProbe}, which validates them. Each served answer is judged against a cold
# run of the same tree.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/run_cache_probe"
require "rigor/cache/store"
require "rigor/configuration"

RSpec.describe "the run-result slot and the presence of its roots (#1962, #1555)" do
  around do |example|
    Dir.mktmpdir("rigor-run-root-presence-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:cache_root) { File.join(Dir.pwd, ".rigor", "cache") }
  let(:overrides) { {} }
  let(:configuration) do
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0).merge(overrides)
    )
  end

  before do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "x = 1\n")
  end

  def rows(diagnostics)
    diagnostics.map { |d| [d.path, d.severity, d.message] }
  end

  def cold(roots)
    rows(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), roots).diagnostics)
  end

  def runner_with_store
    Rigor::Analysis::Runner.new(configuration: configuration, cache_store: Rigor::Cache::Store.new(root: cache_root))
  end

  # The runner's own slot. A fresh `Cache::Store` per call, as a fresh process would have.
  def through_runner(roots)
    rows(guarded_run(runner_with_store, roots).diagnostics)
  end

  def probe(roots)
    result = Rigor::Analysis::RunCacheProbe.new(
      configuration: configuration, cache_root: cache_root, explain: false
    ).serve(roots)
    result && rows(result.diagnostics)
  end

  # Writes the slot, applies `change`, and expects both readers to answer as a cold run of the changed tree: the
  # probe declines the stale slot, the runner recomputes, and the probe then serves what the runner rewrote.
  # Returns the cold rows before and after the change, so a caller can assert the change is one the rows see.
  def expect_matches_cold_after(roots, &change)
    before = cold(roots)
    expect(through_runner(roots)).to eq(before)
    change.call
    after = cold(roots)

    expect(probe(roots)).to be_nil
    expect(through_runner(roots)).to eq(after)
    expect(probe(roots)).to eq(after)
    [before, after]
  end

  def skipped(path, message)
    [[path, :warning, "#{message} (skipped)"]]
  end

  missing = "no such file or directory"
  not_ruby = "not a Ruby file (expected `.rb` or a directory)"

  describe "an analysis root that changes kind (#1962)" do
    it "S1: missing -> empty directory" do
      expect(expect_matches_cold_after(%w[lib x]) { FileUtils.mkdir("x") }).to eq([skipped("x", missing), []])
    end

    it "S2: empty directory -> missing" do
      FileUtils.mkdir("x")
      expect(expect_matches_cold_after(%w[lib x]) { FileUtils.rmdir("x") }).to eq([[], skipped("x", missing)])
    end

    it "S3: missing -> a non-.rb file" do
      expect(expect_matches_cold_after(%w[lib x]) { File.write("x", "") })
        .to eq([skipped("x", missing), skipped("x", not_ruby)])
    end

    it "S4: a non-.rb file -> missing" do
      File.write("x", "")
      expect(expect_matches_cold_after(%w[lib x]) { File.unlink("x") })
        .to eq([skipped("x", not_ruby), skipped("x", missing)])
    end

    it "S5: a directory holding only a non-.rb file -> missing" do
      FileUtils.mkdir("x")
      File.write("x/n.txt", "")
      expect(expect_matches_cold_after(%w[lib x]) { FileUtils.rm_rf("x") }).to eq([[], skipped("x", missing)])
    end

    it "S6: empty directory -> a non-.rb file" do
      FileUtils.mkdir("x")
      expect(expect_matches_cold_after(%w[lib x]) do
        FileUtils.rmdir("x")
        File.write("x", "")
      end).to eq([[], skipped("x", not_ruby)])
    end

    context "with the roots coming from the configuration" do
      let(:overrides) { { "paths" => %w[app lib] } }

      before do
        FileUtils.mkdir("app")
        FileUtils.mv("lib/a.rb", "app/a.rb")
      end

      it "S7: an empty configured root `lib` removed" do
        expect(expect_matches_cold_after(configuration.paths) { FileUtils.rmdir("lib") })
          .to eq([[], skipped("lib", missing)])
      end
    end
  end

  describe "a signature root that appears or vanishes (#1555)" do
    let(:source) { "class A\n  def m(x) = x\nend\nA.new.m(1).foo\n" }
    let(:signature) { "class A\n  def m: (untyped) -> Integer\nend\n" }

    before { File.write("lib/a.rb", source) }

    def messages(rows) = rows.map(&:last)

    it "re-answers when the auto-detected `sig/` is created after the slot was written" do
      before, after = expect_matches_cold_after(%w[lib]) do
        FileUtils.mkdir("sig")
        File.write("sig/a.rbs", signature)
      end
      expect(messages(before)).not_to eq(messages(after))
    end

    context "with a configured signature root" do
      let(:overrides) { { "signature_paths" => %w[types] } }

      it "re-answers when the configured root is created after the slot was written" do
        before, after = expect_matches_cold_after(%w[lib]) do
          FileUtils.mkdir("types")
          File.write("types/a.rbs", signature)
        end
        expect(messages(before)).not_to eq(messages(after))
      end
    end

    # A guard: #979's listing row for `sig/` already covered this before the existence rows.
    it "re-answers when `sig/` is deleted after the slot was written" do
      FileUtils.mkdir("sig")
      File.write("sig/a.rbs", signature)
      before, after = expect_matches_cold_after(%w[lib]) { FileUtils.rm_rf("sig") }
      expect(messages(before)).not_to eq(messages(after))
    end
  end

  context "with a `pre_eval:` entry" do
    let(:overrides) { { "pre_eval" => %w[boot.rb] } }

    it "re-answers when a missing `pre_eval:` file is created after the slot was written" do
      before, after = expect_matches_cold_after(%w[lib]) { File.write("boot.rb", "") }
      expect(before).not_to be_empty
      expect(after).to eq([])
    end
  end

  describe "an unchanged root set" do
    before do
      FileUtils.mkdir("x")
      File.write("x/k.rb", "y = 2\n")
    end

    def served_from_cache?(roots)
      runner = runner_with_store
      guarded_run(runner, roots)
      runner.instance_variable_get(:@run_served_from_cache)
    end

    it "still serves identical warm runs from both readers" do
      through_runner(%w[lib x missing])

      expect(probe(%w[lib x missing])).to eq(skipped("missing", missing))
      expect(served_from_cache?(%w[lib x missing])).to be(true)
    end

    # The `--incremental` slot's existence row does not move on this either: only the root's kind is read.
    it "still serves when a non-.rb file is added inside an existing root" do
      through_runner(%w[lib x])
      File.write("x/notes.txt", "")

      expect(probe(%w[lib x])).to eq([])
      expect(served_from_cache?(%w[lib x])).to be(true)
    end
  end
end
