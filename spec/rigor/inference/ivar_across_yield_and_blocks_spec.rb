# frozen_string_literal: true

require "spec_helper"

# Issue #1402 — an instance variable kept its folded pre-call binding across code that may replace it: a `yield`, a
# proc's call, a `super`, and a block on another receiver whose body calls back into `self` (`[1].each { reset }`).
# A plain self-call already widened it over its class-ivar seed (B2.2, #389); these now widen the same way. A block
# that writes the ivar directly already joined its writes into the continuation (ADR-56); it now carries the
# optimistic mark its writes take, so a miss's `nil` it may store is not folded away. A block that runs on an
# object provably not `self` (`Other.class_eval { … }`) writes that object's ivars and calls its methods, so neither
# changes the caller's ivars; its globals, class variables and `yield`s still count.
#
# Each runtime answer below was checked with Ruby 4.0.5. `dump_type` is itself an implicit-self call, which widens
# every narrowed ivar on the way in, so each probe copies the ivar into a local first.
RSpec.describe "an instance variable across yield, proc calls, super and blocks (issue #1402)" do
  include RunnerHelpers

  # `C#pairs` is declared as the issue declares it: `pairs.first` is then an optimistic read (ADR-101) whose miss
  # answers `nil`.
  def sig = { "c.rbs" => "class Other\nend\n\nclass C\n  def pairs: () -> Array[[String, Integer]]\nend\n" }

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
        @@k = 0

        def initialize
          @y = false
          @x = "s"
          @o = Other.new
          @tag = nil
          @items = []
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

  it "does not count an ivar write or a self-call in a block on an object provably not self" do
    # Ruby: `@o.instance_eval { @x = 1 }` sets `@o`'s `@x`, and `@x` stays `"s"`; a `reset` in the block is
    # `@o`'s method. `Other` and `C` are both declared, so the environment orders them `:disjoint`.
    expect(dumped(klass("def m\n  @x = \"s\"\n  @o.instance_eval { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s"'])
    expect(dumped(klass("def m\n  @x = \"s\"\n  Other.class_eval { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s"'])
    # Ruby: `self.class.class_eval { @x = 1 }` sets the class object's `@x`.
    expect(dumped(klass("def m\n  @x = \"s\"\n  self.class.class_eval { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s"'])
    expect(dumped(klass("def m\n  @y = false\n  @o.instance_eval { reset }\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: false"])
  end

  it "does not count an ivar write or a self-call in a nested block on an object provably not self" do
    nested = "def m\n  @x = \"s\"\n  [1].each { |i| @o.instance_eval { @x = i } }\n  v = @x\n  dump_type(v)\nend\n"
    expect(dumped(klass(nested))).to eq(['dump_type: "s"'])
    nested_call = "def m\n  @y = false\n  [1].each { |i| @o.instance_eval { reset } }\n  v = @y\n  dump_type(v)\nend\n"
    expect(dumped(klass(nested_call))).to eq(["dump_type: false"])
  end

  it "counts a global or class variable written in a nested block on another object" do
    # Ruby: both answer `[1, 2]`; a global is global and a class variable resolves lexically, whatever `self` is.
    global = "def m\n  $t = 0\n  r = [1, 2].map { @o.instance_eval { $t += 1 }; $t }\n  " \
             "if r.first == r.last\n    1\n  end\nend\n"
    expect(rules(klass(global))).not_to include("flow.always-truthy-condition")
    cvar = "def m\n  @@k = 0\n  r = [1, 2].map { @o.instance_eval { @@k += 1 }; @@k }\n  " \
           "if r.first == r.last\n    1\n  end\nend\n"
    expect(rules(klass(cvar))).not_to include("flow.always-truthy-condition")
  end

  it "counts an ivar write in a block whose receiver may be self" do
    # Ruby: each answers `true` — the receiver is `self`.
    via_local = "def m\n  @x = false\n  obj = self\n  obj.instance_eval { @x = true }\n  " \
                "if @x\n    1\n  else\n    2\n  end\nend\n"
    expect(rules(klass(via_local))).not_to include("flow.always-truthy-condition")
    via_tap = "def m\n  @x = false\n  tap { |s| s.instance_eval { @x = true } }\n  if @x\n    1\n  else\n    2\n  " \
              "end\nend\n"
    expect(rules(klass(via_tap))).not_to include("flow.always-truthy-condition")
  end

  it "keeps the write-back for an Object receiver, which is not provably another object (guard)" do
    # Ruby: `false` here, but an `Object` may be `self`; the ADR-56 join / drop stands as on master.
    source = "def m\n  @x = false\n  o = Object.new\n  o.instance_eval { @x = true }\n  v = @x\n  dump_type(v)\nend\n"
    expect(dumped(klass(source))).not_to eq(["dump_type: false"])
  end

  it "counts a yield or a proc call in a block on another object, which runs the method's block" do
    # Ruby: each answers `true`.
    expect(dumped(klass("def m\n  @y = false\n  @o.instance_eval { yield }\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
    source = "def m(&blk)\n  @y = false\n  @o.instance_exec(1) { |a| blk.call }\n  v = @y\n  dump_type(v)\nend\n"
    expect(dumped(klass(source))).to eq(["dump_type: bool"])
  end

  it "widens an ivar past a yield in another call's receiver or arguments" do
    # Ruby: each answers `true`.
    expect(dumped(klass("def m\n  @y = false\n  @items << yield\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
    expect(dumped(klass("def m\n  @y = false\n  puts(yield)\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
  end

  it "keeps a nil-free narrowing from feeding the nil-receiver rule past a proc call or a block's yield" do
    # `@tag`'s seed is `String | nil`; the widened binding takes the ADR-58 mark, as past a condition's call.
    proc_call = "def m(&blk)\n  @tag = \"x\"\n  blk.call\n  @tag.upcase\nend\n"
    expect(rules(klass(proc_call))).not_to include("call.possible-nil-receiver")
    block_yield = "def m\n  @tag = \"x\"\n  [1].each { yield }\n  @tag.upcase\nend\n"
    expect(rules(klass(block_yield))).not_to include("call.possible-nil-receiver")
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

  it "enters a later write-back pass on the optimistic mark an earlier pass's exit took" do
    # Ruby: with `pairs` answering `[["a", 1]]`, then `[["a", 1]]`, then `[]`, the second iteration reads the
    # miss's `nil` the first stored, and `x.nil?` answers `true` there.
    source = "def m\n  x = false\n  pairs.each { |a| puts(\"miss\") if x.nil?; x = pairs.first&.empty? }\nend\n"
    expect(rules(klass(source))).not_to include("flow.always-truthy-condition")
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
