# frozen_string_literal: true

require "spec_helper"

# Issue #1889 — `instance_variable_set` on `self` writes an instance variable that no write node shows. Unseen, the
# binding before the call outlived it: `@n = 0; instance_variable_set(:@n, 5)` kept `@n` on `0`, and a block that
# wrote `@n` only this way never entered the captured-binding name set, so the guard after it folded on correct code.
RSpec.describe "a reflective instance variable write (`instance_variable_set`)" do
  include RunnerHelpers

  def rules_for(body)
    analyze("class C\n  def m(items, o, name)\n#{body}\n  end\nend\n").diagnostics.map(&:rule)
  end

  def flow_rules_for(body)
    rules_for(body).grep(/\Aflow\./)
  end

  def dumped_ivar(body)
    source = "require \"rigor/testing\"\ninclude Rigor::Testing\nclass C\n  def m(name, o)\n#{body}\n    " \
             "v = @n\n    dump_type(v)\n  end\nend\n"
    analyze(source).diagnostics.find { |d| d.message.start_with?("dump_type") }&.message
  end

  it "binds the ivar a Symbol literal names to the value" do
    expect(dumped_ivar("@n = 0\ninstance_variable_set(:@n, 5)")).to eq("dump_type: 5")
    expect(dumped_ivar("@n = 0\nself.instance_variable_set(:@n, 5)")).to eq("dump_type: 5")
  end

  it "binds the ivar a String literal names to the value, as Ruby accepts it" do
    expect(dumped_ivar("@n = 0\ninstance_variable_set(\"@n\", 5)")).to eq("dump_type: 5")
  end

  it "joins Dynamic[top] into a bound ivar when the name is not a literal" do
    expect(dumped_ivar("@n = 0\ninstance_variable_set(name, 5)")).to eq("dump_type: 0 | Dynamic[top]")
    expect(flow_rules_for("@n = 0\ninstance_variable_set(name, 5)\nputs 'x' if @n == 0")).to be_empty
  end

  it "does not count a write on another receiver as a write of self's ivar" do
    expect(dumped_ivar("@n = 0\no.instance_variable_set(:@n, 5)")).to eq("dump_type: 0")
  end

  it "does not pin an ivar a non-escaping block writes reflectively" do
    body = "@n = 0\n[1, 2].each { |e| instance_variable_set(:@n, e) }\nputs 'x' if @n == 0"
    expect(flow_rules_for(body)).to be_empty
    expect(dumped_ivar("@n = 0\n[1, 2].each { |e| instance_variable_set(:@n, e) }")).to eq("dump_type: 0 | 1 | 2")
  end

  it "leaves an ivar on its declaration seed alone when the name is not a literal" do
    source = "require \"rigor/testing\"\ninclude Rigor::Testing\nclass D\n  def initialize = @s = \"x\"\n\n  " \
             "def m(name)\n    instance_variable_set(name, 1)\n    v = @s\n    dump_type(v)\n  end\nend\n"
    expect(analyze(source).diagnostics.find { |d| d.message.start_with?("dump_type") }&.message)
      .to eq('dump_type: "x"')
  end

  it "does not fold the issue's inject, whose block reads the ivar it writes" do
    body = "@n = 0\nt = [1, 2].inject(0) { |a, e| instance_variable_set(:@n, @n + 1); a + @n }\nputs 'x' if t == 0"
    expect(flow_rules_for(body)).to be_empty
  end

  it "enters a repeating block of unknown escape with a nil seed it rewrites reflectively joined with Dynamic[top]" do
    body = "@x = nil\nitems.each { |l| puts @x.size; instance_variable_set(:@x, l.to_s) }"
    expect(rules_for(body)).not_to include("call.undefined-method")
  end
end
