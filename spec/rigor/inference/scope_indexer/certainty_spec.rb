# frozen_string_literal: true

require "spec_helper"

# ADR-119 WD3 — the certainty classifier, one row per region rule. Each row names the `def`s the source writes and
# which of them the classifier must call possible; every other `def` is certain. A row whose possible list is empty is
# a certain control for the rule beside it.
RSpec.describe Rigor::Inference::ScopeIndexer::Certainty do
  def possible_def_names(source)
    root = Prism.parse(source).value
    described_class.possible_nodes(root).grep(Prism::DefNode).map(&:name).sort
  end

  table = {
    "a top-level def" => ["def a = 1", []],
    "a class body def" => ["class C\n  def a = 1\nend", []],
    "a class << self body def" => ["class C\n  class << self\n    def a = 1\n  end\nend", []],
    "a def in an if branch, its predicate certain" =>
      ["if (def p = 1)\n  def a = 1\nelse\n  def b = 1\nend", %i[a b]],
    "a def under an unless modifier" => ["class C\n  def a = 1 unless ENV['X']\nend", %i[a]],
    "a def in a ternary" => ["x ? (def a = 1) : (def b = 1)", %i[a b]],
    "a def in a case branch" => ["case x\nwhen 1 then def a = 1\nelse def b = 1\nend", %i[a b]],
    "a def in a pattern-match branch" => ["case x\nin 1 then def a = 1\nend", %i[a]],
    "a def in a while body" => ["while x\n  def a = 1\nend", %i[a]],
    "a def in a for body" => ["for i in [1]\n  def a = 1\nend", %i[a]],
    "the right of && and ||" => ["(def l = 1) && (def a = 1)\n(def m = 1) || (def b = 1)", %i[a b]],
    "a def in a plain block" => ["class C\n  [1].each { def a = 1 }\nend", %i[a]],
    "a def in a class_eval block" => ["C.class_eval do\n  def a = 1\nend", %i[a]],
    "a def in a lambda" => ["-> { def a = 1 }", %i[a]],
    "a def in BEGIN and END" => ["BEGIN { def a = 1 }\nEND { def b = 1 }", %i[a b]],
    "a def under a rescue modifier" => ["(def a = 1) rescue nil", %i[a]],
    "a begin without rescue: main and ensure" => ["begin\n  def a = 1\nensure\n  def b = 1\nend", []],
    "a begin with rescue: all of it" => ["begin\n  def a = 1\nrescue\n  def b = 1\nelse\n  def c = 1\n" \
                                         "ensure\n  def d = 1\nend", %i[a b c d]],
    "a class body with rescue" => ["class C\n  def a = 1\nrescue\n  def b = 1\nend", %i[a b]],
    "a class reopened under a modifier" => ["class C\n  def a = 1\nend if ENV['X']", %i[a]],
    "a module in a conditional" => ["if x\n  module M\n    def a = 1\n  end\nend", %i[a]],
    "a meta-new constant write block" => ["K = Class.new do\n  def a = 1\nend\nS = Struct.new(:x) do\n  " \
                                          "def b = 1\nend\nD = Data.define(:y)", []],
    "a meta-new or-write block" => ["K ||= Module.new do\n  def a = 1\nend", []],
    "a meta-new write under a conditional" => ["K = Class.new do\n  def a = 1\nend if ENV['X']", %i[a]],
    "a bare factory block" => ["Class.new do\n  def a = 1\nend", []],
    "a factory block inside a plain block" => ["[1].each { Class.new { def a = 1 } }", %i[a]],
    "the argument chain of a certain call" => ["class C\n  private def a = 1\n  memoize def b = 1\nend", []],
    "the arguments of a safe-navigation call" => ["x&.private(def a = 1)", %i[a]],
    "a def inside a method body is never classified" => ["def outer\n  def inner = 1\nend", []]
  }

  table.each do |rule, (source, possible)|
    it "classifies #{rule}" do
      expect(possible_def_names(source)).to eq(possible.sort)
    end
  end

  it "answers the shared frozen empty Set for a file with no possible contribution" do
    root = Prism.parse("class C\n  def a = 1\n  attr_reader :b\nend").value

    expect(described_class.possible_nodes(root)).to equal(described_class::EMPTY)
  end

  it "marks every contribution under a possible region, not only defs" do
    root = Prism.parse("if x\n  class C < Struct.new(:a)\n    attr_reader :b\n    alias c b\n  end\nend").value
    kinds = described_class.possible_nodes(root).map { |node| node.class.name.split("::").last }

    expect(kinds).to include("ClassNode", "CallNode", "AliasMethodNode")
  end
end
