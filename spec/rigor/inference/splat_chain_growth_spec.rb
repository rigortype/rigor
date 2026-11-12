# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #1237 / PR #3097 review — a call with a positional splat re-types its callee with no positional correspondence.
# Such a frame first bypassed the return memo, so a chain whose every level calls the next one twice under a splat
# (`m1(*a) = m2(*a) + m2(1, *a)`) re-walked each level once per path: depth 8 took 4.5 s, depth 10 39 s, and depth 12
# did not finish. The frame now stores under a key of its own, which both calls share, so each level is walked once.
#
# The bound is on the budget-trace counter, not on a wall clock (mutual_recursion_walk_growth_spec.rb says why).
RSpec.describe "a chain of splat calls walks each level a bounded number of times" do
  let(:bt) { Rigor::Inference::BudgetTrace }

  around do |example|
    Dir.mktmpdir("rigor-splat-chain-") do |dir|
      Dir.chdir(dir) do
        bt.enable!
        bt.reset
        example.run
      ensure
        bt.disable!
        bt.reset
      end
    end
  end

  def analyze_file(source)
    FileUtils.mkdir_p("lib")
    File.write("lib/chain.rb", source)
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
  end

  # `m1` .. `m<depth>`, each calling the next twice under a splat, entered once with a splat.
  def chain(depth)
    defs = (1..depth).map { |i| "  def m#{i}(*a) = m#{i + 1}(*a) + m#{i + 1}(1, *a)\n" }.join
    "class C\n#{defs}  def m#{depth + 1}(*a) = a.size\nend\nC.new.m1(*[1])\n"
  end

  it "walks a depth-14 chain linearly" do
    analyze_file(chain(14))

    # 15 levels; the main walk types each `def` once more. Re-walking per path reads 2**14 here.
    expect(bt.snapshot[bt::MEMO_BODY_EVALS]).to be <= 15 * 4
  end
end
