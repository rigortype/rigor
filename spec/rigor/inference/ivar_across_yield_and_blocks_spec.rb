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
        def self.reset = (@y = :class)
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
    # Ruby: `Other.instance_eval { @x = 1 }` sets the class object's `@x`, and `@x` stays `"s"`; a `reset` in the
    # block is `Other.reset`.
    expect(dumped(klass("def m\n  @x = \"s\"\n  Other.instance_eval { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s"'])
    expect(dumped(klass("def m\n  @x = \"s\"\n  Other.class_eval { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s"'])
    # Ruby: `self.class.class_eval { @x = 1 }` sets the class object's `@x`.
    expect(dumped(klass("def m\n  @x = \"s\"\n  self.class.class_eval { @x = 1 }\n  v = @x\n  dump_type(v)\nend\n")))
      .to eq(['dump_type: "s"'])
    expect(dumped(klass("def m\n  @y = false\n  Other.instance_eval { reset }\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: false"])
  end

  it "does not count an ivar write or a self-call in a nested block on an object provably not self" do
    nested = "def m\n  @x = \"s\"\n  [1].each { |i| Other.instance_eval { @x = i } }\n  v = @x\n  dump_type(v)\nend\n"
    expect(dumped(klass(nested))).to eq(['dump_type: "s"'])
    nested_call = "def m\n  @y = false\n  [1].each { Other.instance_eval { reset } }\n  v = @y\n  dump_type(v)\nend\n"
    expect(dumped(klass(nested_call))).to eq(["dump_type: false"])
  end

  it "counts a global or class variable written in a nested block on another object" do
    # Ruby: both answer `[1, 2]`; a global is global and a class variable resolves lexically, whatever `self` is.
    global = "def m\n  $t = 0\n  r = [1, 2].map { Other.instance_eval { $t += 1 }; $t }\n  " \
             "if r.first == r.last\n    1\n  end\nend\n"
    expect(rules(klass(global))).not_to include("flow.always-truthy-condition")
    cvar = "def m\n  @@k = 0\n  r = [1, 2].map { Other.instance_eval { @@k += 1 }; @@k }\n  " \
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

  it "counts an ivar write in a block on a module or class object from a module's or a class object's method" do
    # Ruby: each answers `1` — `self` is the module itself, or `D` when called as `D.ie`.
    always_falsey = lambda do |source|
      rules(source).include?("flow.always-truthy-condition")
    end
    module_function_form = "module Util\n  module_function\n\n  def f\n    @u = false\n    " \
                           "Util.module_eval { @u = true }\n    @u ? 1 : 2\n  end\nend\n"
    expect(always_falsey.call(module_function_form)).to be(false)
    extend_self_form = "module Ext\n  extend self\n\n  def g\n    @u = false\n    Ext.module_eval { @u = true }\n    " \
                       "@u ? 1 : 2\n  end\nend\n"
    expect(always_falsey.call(extend_self_form)).to be(false)
    %w[instance_eval class_eval].each do |name|
      singleton_form = "class C2\n  def self.m\n    @cx = false\n    D2.#{name} { @cx = true }\n    " \
                       "@cx ? 1 : 2\n  end\nend\n\nclass D2 < C2\nend\n"
      expect(always_falsey.call(singleton_form)).to be(false)
    end
  end

  it "counts an ivar write in a block on a class object from a method of Object, whose self may be that class" do
    # Ruby: `Other.zz_probe` answers `true`.
    source = "class Object\n  def zz_probe\n    @q = false\n    Other.class_eval { @q = true }\n    " \
             "@q ? 1 : 2\n  end\nend\n"
    expect(rules(klass("") + source)).not_to include("flow.always-truthy-condition")
  end

  it "widens an ivar past a block argument naming a local proc" do
    # Ruby: `[1].each(&blk)` runs the block, which may call `reset`.
    expect(dumped(klass("def m(&blk)\n  @y = false\n  [1].each(&blk)\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
  end

  it "keeps a nil-free narrowing from feeding the nil-receiver rule past a yield in an argument" do
    source = "def m\n  @tag = \"x\"\n  @items << yield\n  t = @tag\n  t.upcase\nend\n"
    expect(rules(klass(source))).not_to include("call.possible-nil-receiver")
  end

  it "keeps the write-back for an instance receiver, whose class may be a subclass of self's" do
    # Ruby: `d.peer_eval(d)` answers `1` — `D` is a source-only subclass of `C`, which the RBS environment
    # cannot order against it.
    source = "class C\n  def peer_eval(peer)\n    @x = false\n    peer.instance_eval { @x = true }\n    " \
             "@x ? 1 : 2\n  end\nend\n\nclass D < C\nend\n"
    sig = { "a.rbs" => "class C\n  def peer_eval: (D) -> Integer\nend\n" }
    expect(analyze(source, sig: sig).diagnostics.map(&:rule)).not_to include("flow.always-truthy-condition")
  end

  it "counts an ivar write in a block on a module object from a method of a Module subclass" do
    # Ruby: `M2.s` answers `1` — `M2` is a `Meta`, so `self` may be the module object the block runs on.
    source = "class Meta < Module\n  def s\n    @x = false\n    M2.module_eval { @x = true }\n    " \
             "@x ? 1 : 2\n  end\nend\n\nM2 = Meta.new\n\nmodule M2\n  def hello = 1\nend\n"
    expect(analyze(source).diagnostics.map(&:rule)).not_to include("flow.always-truthy-condition")
  end

  it "counts an ivar write in a block on a module object from a method of a namespaced Module subclass" do
    # Ruby: `M2.s` answers `1` — `NS::Meta < NS::Base < Module`, the superclass written relative to `NS`.
    source = "module NS\n  class Base < Module\n  end\n\n  class Meta < Base\n    def s\n      @x = false\n      " \
             "M2.module_eval { @x = true }\n      @x ? 1 : 2\n    end\n  end\nend\n\nM2 = NS::Meta.new\n\n" \
             "module M2\nend\n"
    expect(analyze(source).diagnostics.map(&:rule)).not_to include("flow.always-truthy-condition")
  end

  it "counts an ivar write in a block on a module object from a method of an RBS-declared Module subclass" do
    # The reopening below spells no superclass; only the signature says `Meta3 < Module`, so only the
    # environment's ordering can tell.
    source = "class Meta3\n  def s\n    @x = false\n    M3.module_eval { @x = true }\n    @x ? 1 : 2\n  " \
             "end\nend\n\nM3 = Meta3.new\n\nmodule M3\nend\n"
    sig = { "meta.rbs" => "class Meta3 < Module\n  def s: () -> Integer\nend\n\nM3: Meta3\n" }
    expect(analyze(source, sig: sig).diagnostics.map(&:rule)).not_to include("flow.always-truthy-condition")
  end

  it "counts an ivar write in a block on a module object from a method of a class whose superclass is unresolved" do
    # The analysis knows nothing of `ExternalBase`, which may be `Module` or a subclass of it.
    source = "class Meta4 < ExternalBase\n  def s\n    @x = false\n    M4.module_eval { @x = true }\n    " \
             "@x ? 1 : 2\n  end\nend\n\nM4 = Meta4.new\n\nmodule M4\nend\n"
    expect(analyze(source).diagnostics.map(&:rule)).not_to include("flow.always-truthy-condition")
  end

  it "keeps the write-back for an Object receiver, which is not provably another object (guard)" do
    # Ruby: `false` here, but an `Object` may be `self`; the ADR-56 join / drop stands as on master.
    source = "def m\n  @x = false\n  o = Object.new\n  o.instance_eval { @x = true }\n  v = @x\n  dump_type(v)\nend\n"
    expect(dumped(klass(source))).not_to eq(["dump_type: false"])
  end

  it "counts a yield or a proc call in a block on another object, which runs the method's block" do
    # Ruby: each answers `true`.
    expect(dumped(klass("def m\n  @y = false\n  Other.instance_eval { yield }\n  v = @y\n  dump_type(v)\nend\n")))
      .to eq(["dump_type: bool"])
    source = "def m(&blk)\n  @y = false\n  Other.instance_exec(1) { |a| blk.call }\n  v = @y\n  dump_type(v)\nend\n"
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
    proc_call = "def m(&blk)\n  @tag = \"x\"\n  blk.call\n  t = @tag\n  t.upcase\nend\n"
    expect(rules(klass(proc_call))).not_to include("call.possible-nil-receiver")
    block_yield = "def m\n  @tag = \"x\"\n  [1].each { yield }\n  t = @tag\n  t.upcase\nend\n"
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
    # Ruby: with `pairs` answering `[["a", 1], ["b", 2]]` and then `[]`, the second iteration reads the miss's `nil`
    # the first stored, so `y` ends `true`.
    source = "def m\n  y = nil\n  x = false\n  pairs.each { |a| y = x.nil?; x = pairs.first&.empty? }\n  " \
             "dump_type(y)\nend\n"
    expect(dumped(klass(source))).to contain_exactly(match(/TrueClass|bool/))
  end

  it "does not count an ivar write in a block on another object nested in an escaping closure" do
    source = "def m\n  @x = \"s\"\n  f = -> { Other.instance_eval { @x = 1 } }\n  v = @x\n  dump_type(v)\nend\n"
    expect(dumped(klass(source))).to eq(['dump_type: "s"'])
  end

  it "counts a yield in a block on another object nested in a block" do
    source = "def m\n  @y = false\n  [1].each { Other.instance_eval { yield } }\n  v = @y\n  dump_type(v)\nend\n"
    expect(dumped(klass(source))).to eq(["dump_type: bool"])
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
