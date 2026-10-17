# frozen_string_literal: true

require "spec_helper"

# Issue #1402 — an instance variable kept its folded pre-call binding across code that may replace it: a `yield`, a
# proc's call, a `super`, and a block on another receiver whose body calls back into `self` (`[1].each { reset }`).
# A plain self-call already widened it over its class-ivar seed (B2.2, #389); these now widen the same way. A block
# that writes the ivar directly already joined its writes into the continuation (ADR-56); it now carries the
# optimistic mark its writes take, so a miss's `nil` it may store is not folded away. A block that runs on another
# object (`o.instance_eval { … }`) writes and calls that object's, and changes nothing here.
#
# Each runtime answer below was checked with Ruby 4.0.5. `dump_type` is itself an implicit-self call, which widens
# every narrowed ivar on the way in, so each probe copies the ivar into a local first.
RSpec.describe "an instance variable across yield, proc calls, super and blocks (issue #1402)" do
  include RunnerHelpers

  # `C#pairs` is declared as the issue declares it: `pairs.first` is then an optimistic read (ADR-101) whose miss
  # answers `nil`.
  def sig = { "c.rbs" => "class C\n  def pairs: () -> Array[[String, Integer]]\nend\n" }

  def diagnostics(source)
    analyze("require \"rigor/testing\"\ninclude Rigor::Testing\n\n#{source}", sig: sig).diagnostics
  end

  def dumped(source)
    diagnostics(source).select { |d| d.message.start_with?("dump_type") }.map(&:message)
  end

  def rules(source)
    diagnostics(source).map(&:rule)
  end

  # `C#reset` writes `@y = true` and `@x = "t"`, so their class-ivar seeds are `bool` and `String`. `methods`
  # land in the class body.
  def klass(methods)
    <<~RUBY
      class Other
      end

      class C
        def initialize
          @y = false
          @x = "s"
          @o = Other.new
        end

        def reset
          @y = true
          @x = "t"
        end

        def pairs = [["a", 1]]

      #{methods.gsub(/^(?=.)/, '  ')}end
    RUBY
  end

  it "widens an ivar past a yield, whose block may call back into self" do
    # Ruby: `C.new.m { c.reset }` answers `true`.
    expect(dumped(klass("def m\n  @y = false\n  yield\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
  end

  it "reports nothing on the issue's yield repro" do
    source = klass("def m\n  @y = false\n  yield\n  if (!@y) == false\n    1\n  else\n    2\n  end\nend\n")
    expect(rules(source)).not_to include("flow.always-truthy-condition")
  end

  it "reports nothing on the issue's marked-binding repro (#1401)" do
    source = klass("def m\n  @y = pairs.first&.empty?\n  yield\n  if (!@y) == false\n    1\n  else\n    2\n  " \
                   "end\nend\n")
    expect(rules(source)).not_to include("flow.always-truthy-condition")
  end

  it "widens an ivar past a block on another receiver that calls a method on self" do
    # Ruby: `[1].each { reset }` leaves `@y` `true`.
    expect(dumped(klass("def m\n  @y = false\n  [1].each { reset }\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
  end

  it "widens an ivar past a yield inside a nested block" do
    expect(dumped(klass("def m\n  @y = false\n  [1].each { yield }\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
  end

  it "widens an ivar past a call of the method's block parameter" do
    expect(dumped(klass("def m(&blk)\n  @y = false\n  blk.call\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
    expect(dumped(klass("def m(&blk)\n  @y = false\n  blk.()\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
  end

  it "keeps the binding past a block that only reads the ivar (guard: precision control)" do
    expect(dumped(klass("def m\n  @x = \"s\"\n  [1].each { |i| w = @x }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s"'])
  end

  it "does not count a block that runs on another object" do
    # Ruby: `@o.instance_eval { @x = 1 }` sets `@o`'s `@x`, and `@x` stays `"s"`; a `reset` in the block is
    # `@o`'s method.
    expect(dumped(klass("def m\n  @x = \"s\"\n  @o.instance_eval { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s"'])
    expect(dumped(klass("def m\n  @x = \"s\"\n  Other.class_eval { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s"'])
    expect(dumped(klass("def m\n  @y = false\n  @o.instance_eval { reset }\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: false"])
  end

  it "does not count a write or a self-call in a nested block that runs on another object" do
    nested = "def m\n  @x = \"s\"\n  [1].each { |i| @o.instance_eval { @x = i } }\n  v = @x\n  dump_type(v)\nend\n"
    expect(dumped(klass(nested))).to eq(['dump_type: "s"'])
    nested_call = "def m\n  @y = false\n  [1].each { |i| @o.instance_eval { reset } }\n  v = @y\n  dump_type(v)\nend\n"
    expect(dumped(klass(nested_call))).to eq(["dump_type: false"])
  end

  it "counts a block of instance_eval on self, which runs on this object (guard)" do
    expect(dumped(klass("def m\n  @x = \"s\"\n  instance_eval { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to contain_exactly(match(/\| 1\b/))
  end

  it "joins a block's direct write with the pre-block binding (guard: ADR-56 already did)" do
    # Ruby: `[1].each { @x = 1 }` leaves `1`; a block run zero times leaves `"s"`.
    expect(dumped(klass("def m\n  @x = \"s\"\n  [1].each { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s" | 1'])
  end

  it "keeps the optimistic mark a block's direct write takes" do
    # Ruby: with `pairs` answering `[["a", 1]]` and then `[]`, the block stores the miss's `nil` and `@x.nil?`
    # answers `true`; the inline `pairs.first&.empty?.nil?` types `bool`.
    ivar = "def m\n  @x = false\n  pairs.each { |a| @x = pairs.first&.empty? }\n  v = @x.nil?\n  dump_type(v)\nend\n"
    expect(dumped(klass(ivar))).to eq(["dump_type: bool"])
    local = "def m\n  x = false\n  pairs.each { |a| x = pairs.first&.empty? }\n  v = x.nil?\n  dump_type(v)\nend\n"
    expect(dumped(klass(local))).to eq(["dump_type: bool"])
  end

  it "widens an ivar past a super, which runs the superclass method on self" do
    # Ruby: `D.new.touch` answers `true`: `C#touch` writes it.
    source = klass("def touch = (@y = true)\n") + <<~RUBY
      class D < C
        def other = (@y = true)

        def touch
          @y = false
          super { 1 }
          v = @y
          dump_type(v)
        end
      end
    RUBY
    expect(dumped(source)).to eq(["dump_type: bool"])
  end

  it "leaves loop and while bodies as they were (guard)" do
    loop_body = "def m\n  @y = false\n  loop do\n    reset\n    break\n  end\n  v = @y\n  dump_type(v)\nend\n"
    expect(dumped(klass(loop_body)))
      .to eq(["dump_type: bool"])
    expect(dumped(klass("def m\n  @y = false\n  i = 0\n  while i < 1\n    reset\n    i += 1\n  end\n  v = @y\n  " \
                        "dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
  end
end
