# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# ADR-103 WD13 / issue #382 — the ADR-46 half of the effects sidecar: per-file collections ride the
# incremental snapshot beside `return_summaries`, so a recheck re-collects only the changed closure and
# serves the rest from disk. The fixpoint is NOT persisted — it is re-run over the merged whole every time,
# which is what lets a leaf edit move a caller in a file the recheck never opened.
RSpec.describe "incremental effect collection" do
  # `Mid#run` calls the leaf, so it is in the leaf's dependent closure; `Other#alone` calls nothing and is
  # in nobody's, which is the file the reuse is observed on.
  def write_project(dir)
    File.write(File.join(dir, "leaf.rb"), <<~RUBY)
      class Leaf
        def emit
          puts("leaf")
        end
      end
    RUBY
    File.write(File.join(dir, "mid.rb"), <<~RUBY)
      class Mid
        def run
          Leaf.new.emit
        end
      end
    RUBY
    File.write(File.join(dir, "other.rb"), <<~RUBY)
      class Other
        def alone
          warn("other")
        end
      end
    RUBY
  end

  def configuration(dir, effects: true)
    data = { "paths" => [dir] }
    data["effects"] = {} if effects
    Rigor::Configuration.new(data)
  end

  def session_for(dir, effects: true)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir, effects: effects), paths: [dir])
  end

  # Records the paths the collector was activated for. A file served from the snapshot never appears.
  def collected_files
    seen = []
    allow(Rigor::Effects::Collector).to receive(:collect_for).and_wrap_original do |original, path, &block|
      seen << File.basename(path.to_s)
      original.call(path, &block)
    end
    seen
  end

  def proven(session, symbol)
    entry = session.effect_table[symbol]
    entry.nil? ? nil : entry.proven.to_a
  end

  around do |example|
    Dir.mktmpdir do |dir|
      write_project(dir)
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  it "re-collects only the changed closure and keeps an untouched file's summaries" do
    session = session_for(dir)
    guarded_baseline(session)

    expect(proven(session, "Leaf#emit")).to eq(["io.output.stdout"])
    expect(proven(session, "Other#alone")).to eq(["io.output.stderr"])

    File.write(File.join(dir, "leaf.rb"), <<~RUBY)
      class Leaf
        def emit
          File.read("leaf.txt")
        end
      end
    RUBY
    seen = collected_files
    guarded_recheck(session)

    # `other.rb` is in nobody's closure, so it was never re-analyzed — and its unit is still in the table,
    # which is only possible if its collection came back from the session's own store.
    expect(seen).to include("leaf.rb")
    expect(seen).not_to include("other.rb")
    expect(proven(session, "Other#alone")).to eq(["io.output.stderr"])
    # The fixpoint re-ran over the merged whole, so the caller's reach moved with the leaf.
    expect(proven(session, "Leaf#emit")).to eq(["io.fs.read"])
    expect(proven(session, "Mid#run")).to eq(["io.fs.read"])
  end

  it "drops a removed file's summaries from the merged table" do
    session = session_for(dir)
    guarded_baseline(session)
    FileUtils.rm(File.join(dir, "other.rb"))
    guarded_recheck(session)

    expect(proven(session, "Other#alone")).to be_nil
    expect(proven(session, "Leaf#emit")).to eq(["io.output.stdout"])
  end

  describe "across processes" do
    def snapshot_for(cache)
      Rigor::Cache::IncrementalSnapshot.new(root: cache)
    end

    def run_incremental(cache, effects: true)
      configuration = configuration(dir, effects: effects)
      session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: [dir])
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: configuration, roots: [dir])
      _diagnostics, warm = guarded_run_incremental(session, snapshot: snapshot_for(cache), fingerprint: fingerprint)
      [session, warm]
    end

    around do |example|
      Dir.mktmpdir do |cache|
        @cache = cache
        example.run
      end
    end

    attr_reader :cache

    it "persists the collections and serves the unchanged files from the snapshot" do
      run_incremental(cache)

      seen = collected_files
      session, warm = run_incremental(cache)

      expect(warm).to be(true)
      expect(seen).to be_empty
      expect(proven(session, "Mid#run")).to eq(["io.output.stdout"])
      expect(proven(session, "Other#alone")).to eq(["io.output.stderr"])
    end

    # A snapshot whose summaries were collected under a different vocabulary cannot be partially refreshed:
    # a recheck only re-collects the changed closure, so the merged table would be missing every unchanged
    # file. The session declines the reuse and takes a full baseline — the incremental spelling of "an
    # effects miss recomputes effects".
    it "declines a snapshot whose effects identity moved and re-collects everything" do
      run_incremental(cache)

      real = Rigor::Effects::Registry.default
      bumped = Rigor::Effects::Registry.new(vocabulary_version: real.vocabulary_version + 1, labels: real.labels)
      allow(Rigor::Effects::Registry).to receive(:default).and_return(bumped)
      session, warm = run_incremental(cache)

      expect(warm).to be(false)
      expect(proven(session, "Other#alone")).to eq(["io.output.stderr"])
    end

    it "declines a snapshot written with collection off, and leaves a non-collecting run warm" do
      run_incremental(cache, effects: false)

      _off_session, off_warm = run_incremental(cache, effects: false)
      expect(off_warm).to be(true)

      session, warm = run_incremental(cache)
      expect(warm).to be(false)
      expect(proven(session, "Mid#run")).to eq(["io.output.stdout"])
    end
  end
end
