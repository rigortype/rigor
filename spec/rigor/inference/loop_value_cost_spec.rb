# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #2031 review — a loop's value costs an evaluation of its body, so a loop the statement evaluator already
# evaluated must not be evaluated again by each typing of the node that holds it: a call it is an argument or the
# receiver of, a write whose value it is. Nested eight deep, each spelling took minutes. The statement walk's own
# fixpoint runs at most three passes per loop, so a nesting `depth` deep evaluates at most `3**depth` loops.
loop_spellings = {
  "a call argument" => ->(inner) { "(while c; y = id(#{inner}); break 2 if y; c = false; end)" },
  "a write's value" => ->(inner) { "(while c; y = id(z = #{inner}); break 2 if y; c = false; end)" },
  "a call receiver" => ->(inner) { "(while c; y = id(#{inner}.itself); break 2 if y; c = false; end)" }
}.freeze

RSpec.describe "Loop value evaluation cost" do
  def nest(depth, spelling)
    depth.zero? ? "1" : spelling.call(nest(depth - 1, spelling))
  end

  def evaluations(method_name, body)
    count = 0
    allow_any_instance_of(Rigor::Inference::StatementEvaluator) # rubocop:disable RSpec/AnyInstance
      .to receive(method_name).and_wrap_original do |m, node|
        count += 1
        m.call(node)
      end
    Rigor::Scope.empty.evaluate(Prism.parse("def id(x) = x\nc = cond\nid(#{body})\n").value)
    count
  end

  loop_spellings.each do |name, spelling|
    it "evaluates a loop nested as #{name} once per fixpoint pass, 6 deep" do
      expect(evaluations(:eval_loop, nest(6, spelling))).to be <= 3**6
    end

    it "evaluates a loop nested as #{name} once per fixpoint pass, 8 deep" do
      expect(evaluations(:eval_loop, nest(8, spelling))).to be <= 3**8
    end
  end

  # The pre-existing control: a ternary nested as a call argument is evaluated once per level.
  it "evaluates a nested ternary once per level" do
    body = 8.times.reduce("1") { |inner, _| "(c ? id(#{inner}) : 2)" }
    expect(evaluations(:eval_if, body)).to eq(8)
  end

  it "evaluates a loop again from a scope unlike the one its record holds" do
    node = Prism.parse("c = cond\nwhile c; break c; end").value.statements.body.last
    first = Rigor::Scope.empty.with_local(:c, Rigor::Type::Combinator.constant_of(1))
    second = Rigor::Scope.empty.with_local(:c, Rigor::Type::Combinator.constant_of("s"))
    first.evaluate(node)
    expect(second.type_of(node)).to eq(second.evaluate(node).first)
    expect(second.type_of(node)).not_to eq(first.evaluate(node).first)
  end

  it "types a while loop no break leaves as nil without evaluating it" do
    scope = Rigor::Scope.empty.with_local(:c, Rigor::Type::Combinator.untyped)
    node = Prism.parse("while c; c = false; end").value.statements.body.first
    count = 0
    allow_any_instance_of(Rigor::Inference::StatementEvaluator) # rubocop:disable RSpec/AnyInstance
      .to receive(:eval_loop).and_wrap_original do |m, n|
        count += 1
        m.call(n)
      end
    expect(scope.type_of(node)).to eq(Rigor::Type::Combinator.constant_of(nil))
    expect(count).to eq(0)
  end
end
