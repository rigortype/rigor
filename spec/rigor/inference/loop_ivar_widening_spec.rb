# frozen_string_literal: true

require "spec_helper"

# Issue #1930 — ADR-56 slice B's loop rebind fixpoint widened the locals a `while` / `until` body rebinds and left an
# instance variable on the single body pass, which types the write from the first iteration's locals. After
# `@n = 0; i = 0; while i < k; @n = i + 1; i += 1; end` the exit scope read `@n` as `0 | 1`, so `@n == 3` and `@n > 1`
# folded to always falsey, and a read before the write (`@v.upcase` with `@v = "s"` later in the body) saw only the
# pre-loop `0`. Ruby 4.0.5 witnesses, `k = 3`: `@n == 3` and `@n > 1` are both true and `@n` is `3`; the `@v` loop
# prints `"S"` from its second iteration on.
RSpec.describe "a loop body's instance-variable rebind", type: :runner do
  def analyzed(body)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\nclass W\n  def m(k, c, a)\n#{body}\n  end\nend\n))
  end

  def dumped_type(body)
    analyzed(body).diagnostics.find { |d| d.message.start_with?("dump_type") }&.message&.delete_prefix("dump_type: ")
  end

  def reported_rules(body)
    analyzed(body).diagnostics.filter_map do |diagnostic|
      rule = diagnostic.rule.to_s
      rule if rule == "call.undefined-method" || rule.start_with?("flow.")
    end
  end

  {
    "while" => "while i < k",
    "until" => "until i >= k"
  }.each do |keyword, header|
    describe "a `#{keyword}` body" do
      let(:loop_body) { "@n = 0\ni = 0\n#{header}\n  @n = i + 1\n  i += 1\nend" }

      it "widens the ivar it rebinds with the pre-loop value to the nominal" do
        expect(dumped_type("#{loop_body}\ndump_type(@n)")).to eq("Integer")
      end

      it "does not fold a condition on the rebound ivar" do
        expect(reported_rules("#{loop_body}\nputs 'a' if @n == 3\nputs 'b' if @n > 1")).to be_empty
      end
    end
  end

  # A post-condition loop runs its body once before the test, so Ruby never leaves it with the pre-loop `0` (`k = 0`
  # gives `1`). Rigor seeds the fixpoint with the pre-loop binding as it does for a local, which is wider, never
  # narrower.
  it "widens the ivar a `begin … end while` body rebinds" do
    expect(dumped_type("@n = 0\ni = 0\nbegin\n  @n = i + 1\n  i += 1\nend while i < k\ndump_type(@n)"))
      .to eq("Integer")
  end

  # `loop do` is a block call, typed by the block write-back, not by the loop fixpoint. A guard: it was quiet before.
  it "does not fold a condition on an ivar a `loop do` block rebinds" do
    body = "@n = 0\ni = 0\nloop do\n  break if i >= k\n  @n = i + 1\n  i += 1\nend\nputs 'a' if @n == 3"
    expect(reported_rules(body)).to be_empty
  end

  it "lets the body's own read see the value an earlier iteration stored" do
    body = "@v = 0\ni = 0\nwhile c\n  puts @v.upcase if i > 0\n  @v = 's'\n  i += 1\nend"
    expect(reported_rules(body)).not_to include("call.undefined-method")
  end

  it "lets the body's own read see a value an earlier iteration stored reflectively" do
    body = "@v = 0\ni = 0\nwhile c\n  puts @v.upcase if i > 0\n  instance_variable_set(:@v, 's')\n  i += 1\nend"
    expect(reported_rules(body)).not_to include("call.undefined-method")
  end

  # Issue #1889 joined `Dynamic[top]` into a literal-name `instance_variable_set` inside a `while` body because the
  # fixpoint saw no ivar; the fixpoint now widens it as it widens `@n = …`.
  it "widens an ivar a `while` body rebinds through a literal-name `instance_variable_set`" do
    body = "@n = 0\ni = 0\nwhile i < k\n  instance_variable_set(:@n, i + 1)\n  i += 1\nend\ndump_type(@n)"
    expect(dumped_type(body)).to eq("Integer")
  end

  # A guard: the block write-back already left `@n` unfoldable (`0 | Dynamic[top]`); the fixpoint keeps it so.
  it "does not fold on an ivar a block nested in the body rebinds" do
    body = "@n = 0\ni = 0\nwhile i < k\n  a.each { |x| @n = x }\n  i += 1\nend"
    expect(reported_rules("#{body}\nputs 'a' if @n == 3")).to be_empty
  end

  it "drops a narrowing the body made once the back edge rebinds the ivar" do
    body = "@q = nil\ni = 0\nwhile i < k\n  @q = 1 if @q.nil?\n  @q = nil if i > 2\n  i += 1\nend\ndump_type(@q)"
    expect(dumped_type(body)).to eq("Integer?")
  end

  # A `break` leaves the loop with the arm's binding, which the fall-through drops. Ruby, `k = 3`: `@flag` is `true`.
  it "joins an ivar a `break` path rebinds into the continuation" do
    body = "@flag = false\ni = 0\nwhile i < k\n  i += 1\n  if i == 2\n    @flag = true\n    break\n  end\nend\n" \
           "dump_type(@flag)"
    expect(dumped_type(body)).to eq("bool")
  end

  # Guards: an ivar the body never writes is not widened, and a local widens as it did before.
  it "keeps the exact binding of an ivar the body does not rebind" do
    expect(dumped_type("@p = 0\ni = 0\nwhile i < k\n  i += 1\nend\ndump_type(@p)")).to eq("0")
  end

  it "leaves a local's widening as it was" do
    expect(dumped_type("n = 0\ni = 0\nwhile i < k\n  n = i + 1\n  i += 1\nend\ndump_type(n)")).to eq("Integer")
  end
end
