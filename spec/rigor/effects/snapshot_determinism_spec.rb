# frozen_string_literal: true

require "rigor"
require "rigor/effects/snapshot"

# ADR-103 #381 — the snapshot is a committed file, so "the same tree gives the same bytes" is a contract
# rather than a nicety: a reviewer must be able to read a diff as a change in the code, and a CI machine
# must agree with a laptop. The two axes that could break it are the run order (a pooled run merges
# per-worker collections in completion order) and Hash insertion order inside the document.
RSpec.describe "effect snapshot determinism" do
  def fixture
    File.expand_path("../../integration/fixtures/effects/tracer", __dir__)
  end

  def configuration(workers: 0)
    Rigor::Configuration.new(
      "paths" => [fixture],
      "parallel" => { "workers" => workers },
      "effects" => { "snapshot" => { "reach" => ["*.rb"] } }
    )
  end

  def snapshot_text(workers: 0)
    config = configuration(workers: workers)
    runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
    guarded_run(runner, [fixture])
    Rigor::Effects::Snapshot.build(
      table: runner.effect_table, configuration: config, sources: runner.effect_sources,
      project_root: fixture
    ).to_yaml
  end

  it "writes the same bytes twice over an unchanged tree" do
    first = snapshot_text
    second = snapshot_text

    expect(second).to eq(first)
  end

  # The active `workers > 0` backend for a collecting run is fork (ADR-15 Amendment, pinned by
  # `PoolCoordinator#dispatch_pool`); the per-file collections marshal back with the file's diagnostics.
  it "writes the same bytes pooled as sequentially" do
    expect(snapshot_text(workers: 2)).to eq(snapshot_text)
  end

  it "records both tables over the fixture, so the comparison is not vacuous" do
    text = snapshot_text

    expect(text).to include('"Tracer::Reporter#report":', "reach:\n")
  end
end
