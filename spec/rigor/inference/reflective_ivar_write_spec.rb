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

  def class_rules(source)
    analyze(source).diagnostics.map(&:rule)
  end

  it "widens an ivar on its declaration seed when the name is not a literal" do
    source = "class Seeded\n  def initialize = @k = 0\n\n  def set(name)\n    instance_variable_set(name, 5)\n    " \
             "puts 'seed' if @k == 0\n  end\nend\n"
    expect(class_rules(source).grep(/\Aflow\./)).to be_empty
  end

  it "widens a declaration-seeded ivar a block may write through a name it cannot see" do
    source = "class Seeded\n  def initialize = @k = 0\n\n  def blk(name, items)\n    " \
             "items.each { |v| instance_variable_set(name, v) }\n    puts 'k' if @k == 0\n  end\n\n  " \
             "def inj(name)\n    t = [1, 2].inject(0) { |a, e| instance_variable_set(name, e); a + @k }\n    " \
             "puts 't' if t == 0\n  end\nend\n"
    expect(class_rules(source).grep(/\Aflow\./)).to be_empty
  end

  # A read straight off `@s` is quiet on the `Dynamic[top]` join alone; a copy into a local (`x = @s; x.size`)
  # reports a possible nil unless the widened ivar keeps its declaration mark, straight-line and after a
  # non-escaping block's write-back.
  it "keeps the declaration mark of a nil-seeded ivar it widens" do
    source = "class Lazy\n  def initialize = @s = nil\n  def fill = @s = 'x'\n\n  def m(name)\n    " \
             "instance_variable_set(name, 1)\n    @s.size\n    x = @s\n    x.size\n  end\n\n  " \
             "def blk(name)\n    [1, 2].each { |v| instance_variable_set(name, v) }\n    " \
             "x = @s\n    x.size\n  end\nend\n"
    expect(class_rules(source)).to be_empty
  end

  it "treats a splat argument list as a name it cannot see" do
    expect(dumped_ivar("@n = 0\nargs = name\ninstance_variable_set(*args)")).to eq("dump_type: 0 | Dynamic[top]")
    expect(dumped_ivar("@n = 0\nrest = name\ninstance_variable_set(:@n, *rest)")).to eq("dump_type: 0 | Dynamic[top]")
  end

  it "treats a literal Ruby rejects as a name it cannot see, which only widens" do
    # Ruby raises NameError for `:n` and writes nothing; widening every ivar is the conservative reading.
    expect(dumped_ivar("@n = 0\ninstance_variable_set(:n, 5)")).to eq("dump_type: 0 | Dynamic[top]")
  end

  it "ends a class guard's narrowing of the ivar it writes" do
    source = "require \"stringio\"\nrequire \"rigor/testing\"\ninclude Rigor::Testing\n" \
             "class Poker\n  def initialize(holder) = (@holder = holder)\n  def poke = @holder.touch\nend\n\n" \
             "class Writer\n  def initialize\n    @io = ARGV.empty? ? StringIO.new : STDOUT\n    " \
             "@poker = Poker.new(self)\n  end\n\n  def touch = nil\n\n  def m\n    " \
             "return unless @io.is_a?(StringIO)\n\n    instance_variable_set(:@io, StringIO.new)\n    " \
             "@poker.poke\n    v = @io\n    dump_type(v)\n  end\nend\n"
    expect(analyze(source).diagnostics.find { |d| d.message.start_with?("dump_type") }&.message)
      .to eq("dump_type: StringIO")
  end

  {
    "while" => "while i < k",
    "until" => "until i >= k"
  }.each do |keyword, header|
    it "does not pin an ivar a `#{keyword}` body writes reflectively" do
      body = "k = items.size\n@n = 0\ni = 0\n#{header}\n  instance_variable_set(:@n, i + 1)\n  i += 1\nend\n" \
             "x = @n\nputs 'a' if x == 3\nputs 'b' if x > 1\nputs 'c' if @n > 1"
      expect(flow_rules_for(body)).to be_empty
    end
  end

  it "does not pin an ivar a block may write through a name it cannot see" do
    expect(flow_rules_for("@n = 0\n[1, 2].each { |x| instance_variable_set(name, x) }\nputs 'b' if @n == 0"))
      .to be_empty
    body = "@n = 0\nt = [1, 2].inject(0) { |a, e| instance_variable_set(name, @n + 1); a + @n }\nputs 'x' if t == 0"
    expect(flow_rules_for(body)).to be_empty
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
