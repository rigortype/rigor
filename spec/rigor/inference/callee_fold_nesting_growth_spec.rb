# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# PR #2773 review — the regression gate for a fold nesting through callee frames.
#
# A block fold suppresses the folds below it (`ExpressionTyper#without_block_body_threading`), and the suppression is
# what bounds a callee reached inside a fold: the callee's own block tails are typed without their prefix, so the
# chain of folds stops one level down. Clearing the flag at every callee frame let each level fold again. Where nothing
# below an entry can be stored (the unroll fuel ran out, ADR-84 WD3), each level then re-walked the one below four to
# seven times per evaluation: six layers under six keys took 9,373 body evaluations, six layers under twelve keys
# 121,631 instead of 30, a 33-deep chain did not finish, and a 130-deep one overflowed the stack. The flag stays in force
# across the frame (its order dependence is #2782), so these shapes cost what master's do.
#
# The bounds are on the budget-trace counter, not on a wall clock (mutual_recursion_walk_growth_spec.rb says why).
RSpec.describe "a callee reached inside a block fold does not fold again" do
  let(:bt) { Rigor::Inference::BudgetTrace }

  around do |example|
    Dir.mktmpdir("rigor-fold-nesting-") do |dir|
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
    File.write("lib/view.rb", source)
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
  end

  # `layer0(key)` .. `layer<depth - 1>(key)`, each folding a block whose tail reads the local its prefix bound from the
  # next layer, called from `render` with `keys` distinct Symbol keys.
  def layered(keys:, depth:)
    layers = (0...depth).map do |i|
      inner = i == depth - 1 ? "key.to_s" : "layer#{i + 1}(key)"
      "  def layer#{i}(key)\n    key.to_s.chars.map { |c| v = #{inner}; v }.first\n  end\n"
    end
    calls = (0...keys).map { |k| "    x#{k} = layer0(:k#{k})\n" }.join
    results = (0...keys).map { |k| "x#{k}" }.join(", ")
    render = "  def render\n#{calls}    [#{results}]\n  end\n"
    "class View\n  def show\n    render.size\n  end\n\n#{layers.join("\n")}\n#{render}end\n"
  end

  # `m0(n)` .. `m<depth - 1>(n)`, each folding a block over the next, entered from inside a fold with `arg`.
  def chain(depth:, arg:)
    defs = (0...depth).map do |i|
      inner = i == depth - 1 ? "n" : "m#{i + 1}(n)"
      "  def m#{i}(n)\n    [1].map { |e| v = #{inner}; v }.first\n  end\n"
    end
    "class Foo\n#{defs.join}  def entry\n    [1].map { |e| r = m0(#{arg}); r }\n  end\nend\n"
  end

  it "walks each layer a bounded number of times when the unroll fuel runs out" do
    analyze_file(layered(keys: 6, depth: 6))

    # 36 layer frames under one entry, past the 32-frame fuel. Master reads 18 here; the nested walk read 9,373.
    expect(bt.snapshot[bt::MEMO_BODY_EVALS]).to be <= 36 * 4
  end

  it "walks a chain past the unroll fuel once per level" do
    analyze_file(chain(depth: 33, arg: "1"))

    expect(bt.snapshot[bt::MEMO_BODY_EVALS]).to be <= 33 * 4
  end

  it "analyses a deep chain without overflowing the stack" do
    # An overflow raises out of `guarded_run` and fails the example by itself.
    analyze_file(chain(depth: 150, arg: "rand(9)"))

    expect(bt.snapshot[bt::MEMO_BODY_EVALS]).to be <= 150 * 4
  end
end
