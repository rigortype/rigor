# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #2979 — `K = Struct.new("Named", …)` binds `K` and `Struct::Named` to one class, so a reader of
# `Struct::Named`'s chain in another file depends on the write naming it: an edit that adds or drops the class-name
# String must re-check that reader. The oracle is a full `--no-cache` run of the same tree, as in
# `class_mark_incremental_spec.rb`.
RSpec.describe "Struct.new same-class binding — incremental" do
  def configuration(dir)
    settings = { "paths" => [File.join(dir, "lib")], "signature_paths" => [File.join(dir, "sig")], "workers" => 0 }
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(settings))
  end

  def diagnostics(list)
    list.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def warm_and_cold(files, edits)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "types.rbs"), "class Struct::Named2\nend\n")
      files.each { |name, source| File.write(File.join(dir, "lib", name), source) }
      config = configuration(dir)
      session = Rigor::Analysis::IncrementalSession.new(configuration: config, paths: [File.join(dir, "lib")])
      baseline = diagnostics(guarded_baseline(session))
      edits.each { |name, source| File.write(File.join(dir, "lib", name), source) }
      warm = diagnostics(guarded_recheck(session).diagnostics)
      runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
      [baseline, warm, diagnostics(guarded_run(runner, [File.join(dir, "lib")]).diagnostics)]
    end
  end

  let(:named) { "N = Struct.new(\"Named2\", :n_url) do\n  def own_x = 1\nend\n" }
  let(:unnamed) { "N = Struct.new(:n_url) do\n  def own_x = 1\nend\n" }
  let(:reader) { "class Struct::Named2\n  def go = self.own_x\nend\n" }

  it "re-checks a reopening of Struct::Named when the write gains the class-name String" do
    baseline, warm, cold = warm_and_cold({ "n.rb" => unnamed, "r.rb" => reader }, "n.rb" => named)

    expect([baseline, cold]).to eq([[["r.rb", 2]], []])
    expect(warm).to eq(cold)
  end

  it "re-checks it when the write drops the class-name String" do
    baseline, warm, cold = warm_and_cold({ "n.rb" => named, "r.rb" => reader }, "n.rb" => unnamed)

    expect([baseline, cold]).to eq([[], [["r.rb", 2]]])
    expect(warm).to eq(cold)
  end
end
