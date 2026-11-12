# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #2909 — `SelfPreservingBlock.refined_in_effect?` declines a block's self-preservation when an in-effect
# refinement defines the yielding method, so its answer is a function of another file's `refine` body. A warm
# recheck must re-check the reader when that body gains or loses `def times`; the oracle is a `--no-cache` run.
# The `refinement:times` edge it needs is also recorded by the typer's and the check rule's refined dispatch of the
# same call, so this pins the behaviour rather than `refined_in_effect?`'s own recording.
RSpec.describe "self-preserving block under a refinement — incremental" do
  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                            environment: shared_environment)
  end

  def diagnostics(list)
    list.select { |d| d.rule == "call.undefined-method" }.map { |d| [File.basename(d.path), d.line] }.sort
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

  def refinement(*defs) = "module R\n  refine Integer do\n#{defs.map { |d| "    #{d}\n" }.join}  end\nend\n"

  let(:plain) { refinement("def foo = 1") }
  let(:refined) { refinement("def foo = 1", "def times(&b) = instance_exec(&b)") }
  let(:files) do
    { "helpers.rb" => "def format(x) = 42\n", "use.rb" => "using R\n5.times { format(1).upcase }\n" }
  end

  it "re-checks the reader when the refine body gains times" do
    baseline, warm, cold = warm_and_cold(files.merge("r.rb" => plain), "r.rb" => refined)

    expect(baseline).to eq([["use.rb", 2]])
    expect(cold).to eq([])
    expect(warm).to eq(cold)
  end

  it "re-checks the reader when the refine body loses times" do
    baseline, warm, cold = warm_and_cold(files.merge("r.rb" => refined), "r.rb" => plain)

    expect(baseline).to eq([])
    expect(cold).to eq([["use.rb", 2]])
    expect(warm).to eq(cold)
  end
end
