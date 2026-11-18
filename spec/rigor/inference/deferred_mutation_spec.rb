# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/deferred_mutation"
require "rigor/scope"

# Issue #3340 — which closures stop an emptiness guard from narrowing a local. The end-to-end reading is
# `statement_evaluator/unspelled_content_mutation_spec.rb`; this file pins the scan.
RSpec.describe Rigor::Inference::DeferredMutation do
  # Whether the guard `return if xs.empty?` in a method whose body is `before`, the guard, then `after` is one a
  # later-running closure can falsify.
  def empties?(before, after = "")
    body = Prism.parse("def m(name, blk)\nxs = []\n#{before}\nreturn if xs.empty?\n#{after}\nend").value
                .statements.body.first.body
    guard = body.body.find { |node| node.is_a?(Prism::IfNode) }.predicate
    described_class.empties?(Rigor::Scope.empty.with_match_frame(body), :xs, guard)
  end

  it "answers for a lambda, a proc and a method-defining block that can empty the local" do
    ["f = -> { xs.clear }", "f = lambda { xs.pop }", "f = proc { xs.shift }", "define_method(:z) { xs.replace([]) }",
     "define_singleton_method(:z) { xs.delete(1) }", "on_event { xs.reject! { |x| x } }"].each do |closure|
      expect(empties?(closure)).to be(true), closure
    end
  end

  it "answers for a closure made after the guard, and for one nested in a block that runs at once" do
    expect(empties?("", "f = -> { xs.clear }")).to be(true)
    expect(empties?("[1].each { register(-> { xs.clear }) }")).to be(true)
    expect(empties?("f = -> { [1].each { xs.clear } }")).to be(true)
  end

  it "answers for the forms that reach an emptying mutator without spelling it on the local" do
    ["f = -> { xs.send(:clear) }", "f = -> { xs.method(:pop).call }", "f = -> { [xs].each(&:clear) }",
     "f = -> { xs.send(name) }", "f = -> { xs.instance_eval { clear } }", "f = -> { xs.method(name).call }",
     "f = -> { (flag ? xs : ys).clear }"].each do |closure|
      expect(empties?(closure)).to be(true), closure
    end
  end

  it "answers nothing for a closure that only reads the local or cannot empty it" do
    ["f = -> { xs.size }", "f = -> { xs << 1 }", "f = -> { xs.sort! }", "f = -> { xs.send(:push, 1) }",
     "f = -> { [xs].each(&:size) }", "f = -> { ys.clear }", "f = -> { xs.instance_eval { size } }"].each do |closure|
      expect(empties?(closure)).to be(false), closure
    end
  end

  it "answers nothing for a block that runs at once, a shadowing parameter, or a nested def" do
    ["[1].each { xs.clear }", "xs.tap { xs.clear }", "f = ->(xs) { xs.clear }", "f = proc { |;xs| xs.clear }",
     "f = -> { def wipe(xs) = xs.clear }"].each do |closure|
      expect(empties?(closure)).to be(false), closure
    end
  end

  it "answers nothing for the closure the guard itself sits in" do
    body = Prism.parse("def m\nxs = []\nproc do\nnext if xs.empty?\nxs.pop\nend\nend").value.statements.body.first.body
    guard = body.body.last.block.body.body.first.predicate
    expect(described_class.empties?(Rigor::Scope.empty.with_match_frame(body), :xs, guard)).to be(false)
  end

  it "answers nothing where no frame is stamped" do
    guard = Prism.parse("xs = []\nxs.empty?").value.statements.body.last
    expect(described_class.empties?(Rigor::Scope.empty, :xs, guard)).to be(false)
  end
end
