# frozen_string_literal: true

# Issue #2515 — a hand-off on an untyped receiver inside a callee resolves by name to the user instance defs of that
# name (`StatementEvaluator#named_instance_callees`). The name index behind it is a function of the discovery alone,
# so its run-scoped memo is keyed by discovery: one thread answers each discovery its own defs.
require "spec_helper"
require "rigor/analysis/dependency_recorder"

RSpec.describe "the same-named instance def index memo (#2515)" do
  let(:caller_source) do
    <<~RUBY
      class Opts
        def run(acc, h)
          fwd(acc, h)
          fwd_d(acc, h)
        end

        def fwd(acc, h) = h.c(acc)

        def fwd_d(acc, h) = h.d(acc)
      end
    RUBY
  end

  def floored_with(seed_source, name = :fwd)
    seed_program = Prism.parse(seed_source).value
    seed = Rigor::Inference::ScopeIndexer.index(seed_program, default_scope: Rigor::Scope.empty)[seed_program]
    program = Prism.parse(caller_source).value
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: seed)
    call = nil
    Rigor::Source::NodeWalker.each(program) { |node| call ||= node if node.is_a?(Prism::CallNode) && node.name == name }
    Rigor::Inference::StatementEvaluator.new(scope: index[call]).content_mutated_arguments(call).map(&:name)
  end

  it "answers each discovery its own same-named defs for one shared caller" do
    writer = "class Helper\n  def c(acc) = acc << 1\nend\n"
    reader = "class Helper\n  def c(acc) = acc.size\nend\n"
    elsewhere = "class Other\n  def c(acc) = acc << 1\nend\n"
    none = "class Helper\n  def d(acc) = acc << 1\nend\n"

    expect([floored_with(writer), floored_with(elsewhere), floored_with(reader), floored_with(none)])
      .to eq([[:acc], [:acc], [], []])
  end

  it "keys the memo by the called name as well as the discovery" do
    seed = "class Helper\n  def c(acc) = acc << 1\nend\nclass Other\n  def d(acc) = acc << 1\nend\n"

    expect([floored_with(seed, :fwd), floored_with(seed, :fwd_d)]).to eq([[:acc], [:acc]])
  end

  # A hit does not reach the scope, so the evaluator files the reads itself when a recorder is active.
  it "still records its reads in a recording window after the memo was filled outside one" do
    seed_program = Prism.parse("class Helper\n  def c(acc) = acc.size\nend\nclass Sub < Helper\nend\n").value
    seed = Rigor::Inference::ScopeIndexer.index(seed_program, default_scope: Rigor::Scope.empty)[seed_program]
    program = Prism.parse(caller_source).value
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: seed)
    call = nil
    Rigor::Source::NodeWalker.each(program) { |node| call ||= node if node.is_a?(Prism::CallNode) && node.name == :fwd }
    floor = -> { Rigor::Inference::StatementEvaluator.new(scope: index[call]).content_mutated_arguments(call) }

    floor.call
    record = Rigor::Analysis::DependencyRecorder.record_for("lib/opts.rb", &floor)

    expect(record.missing).to include("defines:c", "subclass_of:Helper")
  end

  it "answers the same under a memo-audit recomputation" do
    writer = "class Helper\n  def c(acc) = acc << 1\nend\n"
    was = Rigor::Inference::MemoAudit.enabled?
    Rigor::Inference::MemoAudit.enable!
    begin
      expect([floored_with(writer), floored_with(writer)]).to eq([[:acc], [:acc]])
    ensure
      Rigor::Inference::MemoAudit.disable! unless was
    end
  end
end
