# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #2031 review — a loop's value costs an evaluation of its body, so a loop nested as another loop's call
# operand must not be evaluated again for each typing of the call (`id((while c; y = id((while …)); …; end))`).
RSpec.describe "Loop value evaluation cost" do
  def nest(depth)
    return "1" if depth.zero?

    "(while c; y = id(#{nest(depth - 1)}); break 2 if y; c = false; end)"
  end

  def loop_evaluations(depth)
    count = 0
    allow_any_instance_of(Rigor::Inference::StatementEvaluator) # rubocop:disable RSpec/AnyInstance
      .to receive(:eval_loop).and_wrap_original do |m, node|
      count += 1
      m.call(node)
    end
    source = "def id(x) = x\nc = cond\nid(#{nest(depth)})\n"
    Rigor::Scope.empty.evaluate(Prism.parse(source).value)
    count
  end

  # The statement walk's own fixpoint passes grow about ninefold per two levels; typing each loop operand again
  # from the call grew it about thirty-sixfold.
  it "grows by the statement walk's passes alone as loops nest in call operands" do
    shallow = loop_evaluations(4)
    deep = loop_evaluations(6)
    expect(deep).to be < shallow * 12
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
