# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #2767 — an ADR-55 fixpoint evaluates a recursive method's body several times from the same body scope object,
# each time under a wider summary assumption. A loop value (`LoopValueRecord`) or an inject accumulator recorded in one
# iteration matched the next iteration's read by scope identity and answered it with the narrower iterate, so the
# fixpoint converged on it: `q` below typed `[bot]`. A record now answers only a read in the summary generation it was
# written in, so the answer is the one typing gives with the records off.
RSpec.describe "loop and inject records across ADR-55 fixpoint iterations (#2767)" do
  programs = {
    "a loop in an array literal" =>
      "def q(n) = [(while true; break(n.zero? ? 1 : q(n - 1)); end)]\nv = P.new.q(ARGV.size + 1)",
    "a loop as a call argument" =>
      "def foo(x) = [x]\ndef q(n) = foo((while true; break(n.zero? ? :a : q(n - 1)); end))\nv = P.new.q(ARGV.size + 1)",
    "a loop in a hash value" =>
      "def q(n) = { k: (while true; break(n.zero? ? 0 : q(n - 1)); end) }\nv = P.new.q(ARGV.size + 1)"
  }.freeze

  # The type of the trailing `v = …` write, typed from the scope the indexer recorded for it, as `rigor type-of` does.
  def typed(source)
    body, call = source.split("\nv = ")
    tree = Prism.parse("class P\n#{body}\nend\nv = #{call}\n").value
    index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: Rigor::Scope.empty)
    write = tree.statements.body.last
    index[write].type_of(write)
  end

  def typed_without_records(source)
    allow(Rigor::Inference::LoopValueRecord).to receive(:fetch).and_return(nil)
    allow(Rigor::Inference::ExpressionTyper).to receive(:recorded_inject_accumulator).and_return(nil)
    typed(source)
  end

  programs.each do |name, source|
    it "types #{name} as typing with the records off does" do
      with_records = typed(source)
      expect(with_records).to eq(typed_without_records(source))
      expect(with_records.describe(:short)).not_to include("bot")
    end
  end

  it "still serves a record within one generation (control)" do
    source = "def id(x) = x\nc = cond\nid((while c; y = id(c); break 2 if y; c = false; end))\n"
    hits = 0
    allow(Rigor::Inference::LoopValueRecord).to receive(:fetch).and_wrap_original do |original, *args|
      original.call(*args).tap { |value| hits += 1 if value }
    end
    Rigor::Scope.empty.evaluate(Prism.parse(source).value)
    expect(hits).to be_positive
  end
end
