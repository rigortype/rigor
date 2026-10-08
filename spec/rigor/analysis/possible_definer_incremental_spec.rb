# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-119 WD3 — a certainty-only edit keeps every `def` line and envelope (`class D … end` → `class D … end if X`),
# so without its own part in the ADR-89 declaration signature a warm recheck would skip the consumer whose arity
# read now declines. The oracle is a full `--no-cache` run of the same tree, as in
# `unsettled_chain_incremental_spec.rb`.
RSpec.describe "possible definer — incremental" do
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

  def warm_and_cold(files, edits)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
      session = session_for(dir)
      baseline = diagnostics(guarded_baseline(session))
      edits.each { |name, source| File.write(File.join(dir, name), source) }
      [baseline, diagnostics(guarded_recheck(session).diagnostics), full_run(dir)]
    end
  end

  let(:certain) { { "d.rb" => "class D\n  def go(a) = a\nend\n", "b.rb" => "D.new.go(1, 2)\n" } }
  let(:possible) { "class D\n  def go(a) = a\nend if ENV[\"X\"]\n" }

  it "re-checks the consumer when a modifier makes its definer possible" do
    baseline, warm, cold = warm_and_cold(certain, "d.rb" => possible)

    expect(baseline).to eq([["b.rb", 1]])
    expect(cold).to eq([])
    expect(warm).to eq(cold)
  end

  it "re-checks the consumer when the modifier goes and the definer is certain again" do
    baseline, warm, cold = warm_and_cold(certain.merge("d.rb" => possible), certain)

    expect(baseline).to eq([])
    expect(cold).to eq([["b.rb", 1]])
    expect(warm).to eq(cold)
  end
end
