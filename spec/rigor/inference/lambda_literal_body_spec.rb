# frozen_string_literal: true

require "spec_helper"

# Issue #878 — `->() { }` and `lambda { }` build the same object, so they must type the same.
#
# `lambda { }` is an ordinary call carrying a `Prism::BlockNode` and is statement-evaluated; the `->`
# spelling had no entry in `StatementEvaluator`'s dispatch table, so its body was only ever typed as an
# expression. Reads of enclosing locals and literal receivers inside it still reported — the rule walker
# falls back to the enclosing method's scope — but a write made INSIDE the body joined no scope, so every
# later read of that local in the body kept its pre-write type.
#
# Every example is a pair: the `->` spelling and its `lambda { }` twin must produce the same messages. The
# pairing is the assertion, not the individual message — the bug is a divergence between two spellings of
# one object, and only a paired assertion can go red on either half drifting.
RSpec.describe "a lambda literal's body binds its local writes (#878)", type: :runner do
  def undefined_messages(source)
    analyze(source).diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  # The two spellings are checked in ONE run so a message can be compared verbatim: the suffixed method
  # names make the pair's two diagnostics distinguishable, and `sub` maps one onto the other.
  def expect_parity(arrow:, block:, suffix:)
    messages = undefined_messages("def arrow_form\n#{arrow}\nend\n\ndef block_form\n#{block}\nend\n")
    arrow_messages = messages.grep(/arrow_#{suffix}/).map { |m| m.sub("arrow_", "block_") }
    expect(arrow_messages).to eq(messages.grep(/block_#{suffix}/))
  end

  it "reports a write to a parameter identically to `lambda { |y| }`" do
    expect_parity(
      arrow: "->(y) { y = 1; y.arrow_param }",
      block: "lambda { |y| y = 1; y.block_param }",
      suffix: "param"
    )
  end

  it "reports a write to a body-introduced local identically to `lambda { }`" do
    expect_parity(
      arrow: "-> { z = 1; z.arrow_local }",
      block: "lambda { z = 1; z.block_local }",
      suffix: "local"
    )
  end

  it "reports a read of an enclosing local identically to `lambda { }`" do
    expect_parity(
      arrow: "x = 1; ->(_u) { x.arrow_capture }",
      block: "x = 1; lambda { |_u| x.block_capture }",
      suffix: "capture"
    )
  end

  it "reports a literal receiver identically to `lambda { }`" do
    expect_parity(
      arrow: '->(_u) { "lit".arrow_literal }',
      block: 'lambda { |_u| "lit".block_literal }',
      suffix: "literal"
    )
  end

  it "types a defaulted parameter identically to `lambda { |y = 2| }`" do
    expect_parity(
      arrow: "->(y = 2) { y.arrow_default }",
      block: "lambda { |y = 2| y.block_default }",
      suffix: "default"
    )
  end

  it "binds a write inside a `->` nested in a block" do
    messages = undefined_messages(<<~RUBY)
      def nested
        [1].each do |n|
          ->(m) { m = n; m.frobnicate }
        end
      end
    RUBY

    expect(messages).to eq(["undefined method `frobnicate' for 1"])
  end

  # The continuation half. A lambda literal outlives the expression exactly as the Proc `lambda` returns
  # does, so a local it can rebind must lose its narrowing either way — the `->` form used to keep the
  # pre-lambda binding and report on a program the runtime can make work.
  it "drops the narrowing of a rebound enclosing local identically to `lambda { }`" do
    messages = undefined_messages(<<~RUBY)
      def arrow_form
        x = 1
        -> { x = "s" }
        x.arrow_after
      end

      def block_form
        x = 1
        lambda { x = "s" }
        x.block_after
      end
    RUBY

    expect(messages).to be_empty
  end
end
