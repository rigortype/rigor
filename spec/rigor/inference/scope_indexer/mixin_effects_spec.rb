# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::MixinEffects` is what the include walk and the extend walk both ask about a
# call that mixes a module in, or may. The examples hand a public function a call node of a parsed snippet, the owner
# a walk would have resolved and a `MixinAccumulator`, and read back what it answers and what it taints: no walk runs,
# apart from the examples that pin the callers.
RSpec.describe Rigor::Inference::ScopeIndexer::MixinEffects do
  let(:indexer) { Rigor::Inference::ScopeIndexer }

  # What an owner side lists when its order is unknown, and when its set of modules is unknown too.
  def wildcard = ["*"]

  def unnamed = ["*", "?"]

  # The kinds each walk hands the computed-`send` taint.
  def instance_kinds = %i[include prepend]

  def extend_kinds = %i[extend]

  def private_constants = %i[HOOK_DEFS LOCAL_SCOPE_BOUNDARIES MIXIN_EVAL_CALLS]

  def parse(source)
    Prism.parse(source).value
  end

  # Every call of `name` in a snippet, in source order.
  def calls(source, name)
    found = []
    walk = lambda do |node|
      found << node if node.is_a?(Prism::CallNode) && node.name == name
      node.compact_child_nodes.each(&walk)
    end
    walk.call(source.is_a?(String) ? parse(source) : source)
    found
  end

  def call(source, name) = calls(source, name).first

  # A mixin call on a hook's parameter: `base` is a local there, not a call.
  def hook_call(body, name) = call("def self.included(base)\n  #{body}\nend\n", name)

  # Hands the block a fresh accumulator, inside a hook whose parameter is `base` when asked, and answers what the
  # block answered and what it tainted: `{owner => {side => names}}`.
  def with_accumulator(hook: false)
    accumulator = indexer::MixinAccumulator.new
    answer = hook ? accumulator.with_hook_params([:base]) { yield accumulator } : yield(accumulator)
    [answer, accumulator.unpositioned]
  end

  describe ".program_statements" do
    it "answers the statements of a program, and any other node as it is" do
      program = parse("x = 1\n")

      expect(described_class.program_statements(program)).to equal(program.statements)
      expect(described_class.program_statements(program.statements)).to equal(program.statements)
      expect(described_class.program_statements(nil)).to be_nil
    end
  end

  describe ".mixin_effects" do
    def effects(node, kind, current_class = "C", prefix: [], in_singleton: false, hook: false)
      with_accumulator(hook: hook) do |accumulator|
        described_class.mixin_effects(node, kind, prefix, current_class, accumulator, in_singleton: in_singleton)
      end.first
    end

    it "names the instance side of the enclosing class for a receiverless `include` or `prepend`" do
      expect(effects(call("include M\n", :include), :include)).to eq([["C", :include]])
      expect(effects(call("prepend M\n", :prepend), :prepend)).to eq([["C", :include]])
    end

    it "names the singleton side of the enclosing class for a receiverless `extend`" do
      expect(effects(call("extend M\n", :extend), :extend)).to eq([["C", :extend]])
    end

    it "reads a `self.` receiver as it reads none" do
      expect(effects(call("self.include M\n", :include), :include)).to eq([["C", :include]])
      expect(effects(call("self.extend M\n", :extend), :extend)).to eq([["C", :extend]])
    end

    # Inside `class << self` an `include` reaches the singleton, and an `extend` the singleton's own singleton.
    it "flips `include` and `prepend` to the singleton side inside `class << self`, and names no owner for `extend`" do
      expect(effects(call("include M\n", :include), :include, in_singleton: true)).to eq([["C", :extend]])
      expect(effects(call("prepend M\n", :prepend), :prepend, in_singleton: true)).to eq([["C", :extend]])
      expect(effects(call("extend M\n", :extend), :extend, in_singleton: true)).to eq([])
      expect(effects(call("self.extend M\n", :extend), :extend, in_singleton: true)).to eq([])
    end

    it "names nothing where the walk has no enclosing class" do
      expect(effects(call("include M\n", :include), :include, nil)).to eq([])
      expect(effects(call("singleton_class.include M\n", :include), :include, nil)).to eq([])
    end

    it "names the singleton side for a `singleton_class` receiver on the lexical self, whatever the kind" do
      expect(effects(call("singleton_class.include M\n", :include), :include)).to eq([["C", :extend]])
      expect(effects(call("self.singleton_class.extend M\n", :extend), :extend)).to eq([["C", :extend]])
    end

    it "does not read a `singleton_class` call with arguments, or on another receiver, as the singleton" do
      expect(effects(call("singleton_class(1).include M\n", :include), :include)).to eq([])
      expect(effects(call("K.singleton_class.include M\n", :include), :include)).to eq([])
      expect(effects(call("other_class.include M\n", :include), :include)).to eq([])
    end

    it "names the class a constant receiver names, on the side of the kind" do
      expect(effects(call("K.include M\n", :include), :include)).to eq([["K", :include]])
      expect(effects(call("K.prepend M\n", :prepend), :prepend)).to eq([["K", :include]])
      expect(effects(call("K.extend M\n", :extend), :extend)).to eq([["K", :extend]])
      expect(effects(call("K.include M\n", :include), :include, in_singleton: true)).to eq([["K", :include]])
    end

    it "resolves a constant receiver through the nesting the walk is in" do
      declared = "module Api; class K; end; K.include M; end\n"

      expect(effects(call(declared, :include), :include, "Api", prefix: ["Api"])).to eq([["Api::K", :include]])
      expect(effects(call("module Api; K.include M; end\n", :include), :include, "Api", prefix: ["Api"]))
        .to eq([["K", :include]])
    end

    it "names nothing for a receiver that is an object of its own" do
      expect(effects(call("obj.extend(M)\n", :extend), :extend)).to eq([])
      expect(effects(call("@ids.prepend(1)\n", :prepend), :prepend)).to eq([])
      expect(effects(call("[1, 2].include M\n", :include), :include)).to eq([])
      expect(effects(call("(x).include M\n", :include), :include)).to eq([])
    end

    it "names both sides of the enclosing class for a call on a hook's parameter" do
      node = hook_call("base.include M", :include)

      expect(effects(node, :include, hook: true)).to eq([["C", :include], ["C", :extend]])
      expect(effects(hook_call("base.extend M", :extend), :extend, hook: true))
        .to eq([["C", :include], ["C", :extend]])
      expect(effects(node, :include, in_singleton: true, hook: true)).to eq([["C", :include], ["C", :extend]])
      expect(effects(node, :include, nil, hook: true)).to eq([])
    end

    it "reads a chain of calls with no arguments off a hook's parameter as the parameter" do
      expect(effects(hook_call("base.singleton_class.include M", :include), :include, hook: true))
        .to eq([["C", :include], ["C", :extend]])
      expect(effects(hook_call("base.foo.bar.include M", :include), :include, hook: true))
        .to eq([["C", :include], ["C", :extend]])
      expect(effects(hook_call("base.foo(1).include M", :include), :include, hook: true)).to eq([])
    end

    it "reads a local as a hook's parameter only inside the hook, and only that local" do
      expect(effects(hook_call("base.include M", :include), :include)).to eq([])
      expect(effects(hook_call("other = 1; other.include M", :include), :include, hook: true)).to eq([])
      expect(effects(hook_call("@base.include M", :include), :include, hook: true)).to eq([])
    end
  end

  describe ".taint_unrecorded_mixin" do
    def taint(node, kind, effects, hook: false)
      with_accumulator(hook: hook) do |accumulator|
        described_class.taint_unrecorded_mixin(node, kind, node.arguments&.arguments || [], effects, accumulator)
      end.last
    end

    let(:instance) { [["C", :include]] }
    let(:singleton) { [["C", :extend]] }
    let(:both) { [["C", :include], ["C", :extend]] }

    it "taints the instance side, with the unnamed marker when an argument is no constant (#2991)" do
      expect(taint(call("include helper\n", :include), :include, instance)).to eq("C" => { include: unnamed })
    end

    it "lists the unnamed marker for a splat, a name beside a constant, and a `self` argument" do
      ["include(*MODS)", "include(M, helper)", "include(self)", "prepend(helper)"].each do |source|
        node = parse("#{source}\n").statements.body.first

        expect(taint(node, node.name, instance)).to eq("C" => { include: unnamed }), source
      end
    end

    it "taints the order alone when every argument is a constant" do
      expect(taint(call("include M, A::B\n", :include), :include, instance)).to eq("C" => { include: wildcard })
    end

    it "taints the order alone for a call with no argument" do
      expect(taint(call("include\n", :include), :include, instance)).to eq("C" => { include: wildcard })
    end

    # A `Module.new { … }` argument keeps its #2975 reading: the walk does not name it, and it is not unnamed.
    it "does not read a `Module.new` argument as unnamed" do
      expect(taint(call("include Module.new { def x; end }\n", :include), :include, instance))
        .to eq("C" => { include: wildcard })
    end

    it "lists the unnamed marker on the singleton side for an `extend` whose argument is no constant (#2994)" do
      expect(taint(call("extend helper\n", :extend), :extend, singleton)).to eq("C" => { extend: unnamed })
    end

    it "taints the singleton side's order alone for an `extend` of constants" do
      expect(taint(call("extend M\n", :extend), :extend, singleton)).to eq("C" => { extend: wildcard })
    end

    # An `extend` mixes nothing into the instance side, so it never lists the unnamed marker there.
    it "reads each side by its own rule when a call reshapes both" do
      expect(taint(call("extend helper\n", :extend), :extend, both))
        .to eq("C" => { include: wildcard, extend: unnamed })
    end

    it "lists the unnamed marker on both sides for an `include` of no constant that reaches both" do
      expect(taint(call("include helper\n", :include), :include, both))
        .to eq("C" => { include: unnamed, extend: unnamed })
    end

    it "taints each owner the walk resolved, on its side" do
      expect(taint(call("include helper\n", :include), :include, [["A", :include], ["B", :extend]]))
        .to eq("A" => { include: unnamed }, "B" => { extend: unnamed })
    end

    it "taints nothing when the call reshapes nothing" do
      expect(taint(call("include helper\n", :include), :include, [])).to eq({})
    end

    # `base` is the includer, which the walk cannot name: the module it mixes in is unnamed even when a constant
    # spells it, and it extends the includer, not the module the hook is written in.
    it "lists the unnamed marker on the instance side alone for a hook parameter's `include`" do
      expect(taint(hook_call("base.include M", :include), :include, both, hook: true))
        .to eq("C" => { include: unnamed, extend: wildcard })
    end

    it "keeps the singleton side unnamed-free for a hook parameter's call, whatever its arguments" do
      expect(taint(hook_call("base.include(*X)", :include), :include, both, hook: true))
        .to eq("C" => { include: unnamed, extend: wildcard })
    end

    it "taints the order alone, on both sides, for a hook parameter's `extend`" do
      expect(taint(hook_call("base.extend(*X)", :extend), :extend, both, hook: true))
        .to eq("C" => { include: wildcard, extend: wildcard })
    end

    it "reads the parameter as a hook's only inside the hook" do
      expect(taint(hook_call("base.include M", :include), :include, both))
        .to eq("C" => { include: wildcard, extend: wildcard })
    end

    # `base.singleton_class.include M` mixes nothing into the instance side: its order alone is tainted there.
    it "does not list the unnamed marker on the instance side for a `singleton_class` receiver" do
      expect(taint(hook_call("base.singleton_class.include M", :include), :include, both, hook: true))
        .to eq("C" => { include: wildcard, extend: wildcard })
      expect(taint(call("x.singleton_class.include helper\n", :include), :include, instance))
        .to eq("C" => { include: wildcard })
    end

    it "lists the unnamed marker on the singleton side for a `singleton_class` receiver's `include` of no constant" do
      expect(taint(hook_call("base.singleton_class.include(*X)", :include), :include, both, hook: true))
        .to eq("C" => { include: wildcard, extend: unnamed })
      expect(taint(call("singleton_class.include helper\n", :include), :include, singleton))
        .to eq("C" => { extend: unnamed })
    end
  end

  describe ".taint_computed_mixin_send" do
    # The class or module body of the snippet is registered with the accumulator, as the walks do (unless
    # `register: false`), and the first call of `name:` (`send`) is asked about, for `current_class:` (`"C"`).
    def taint(source, kinds, side, hook: false, **options)
      root = parse(source)
      node = call(root, options.fetch(:name, :send))
      with_accumulator(hook: hook) do |accumulator|
        accumulator.class_body(root.statements.body.first.body) unless options[:register] == false
        described_class.taint_computed_mixin_send(node, options.fetch(:current_class, "C"), accumulator, kinds, side,
                                                  **options.slice(:in_singleton))
      end.last
    end

    def instance_taint(body, **) = taint("class C\n#{body}\nend\n", %i[include prepend], :include, **)

    it "lists the unnamed marker on the side it is asked for, for a `send` whose name is computed (#3006)" do
      expect(instance_taint("  send(m, X)")).to eq("C" => { include: unnamed })
    end

    it "taints the singleton side when the extend walk asks" do
      expect(taint("class C\n  send(m, X)\nend\n", extend_kinds, :extend)).to eq("C" => { extend: unnamed })
    end

    it "reads `public_send`, `__send__` and a `self.` receiver alike" do
      expect(instance_taint("  public_send(m, X)", name: :public_send)).to eq("C" => { include: unnamed })
      expect(instance_taint("  __send__(m, X)", name: :__send__)).to eq("C" => { include: unnamed })
      expect(instance_taint("  self.send(m, X)")).to eq("C" => { include: unnamed })
    end

    it "taints nothing with no enclosing class" do
      expect(instance_taint("  send(m, X)", current_class: nil)).to eq({})
    end

    it "taints nothing for a name a literal spells" do
      expect(instance_taint("  send(:foo, X)")).to eq({})
      expect(instance_taint("  send('foo', X)")).to eq({})
    end

    it "taints nothing for a call that is no `send`, or a `send` on another receiver" do
      expect(instance_taint("  foo(m, X)", name: :foo)).to eq({})
      expect(instance_taint("  obj.send(m, X)")).to eq({})
      expect(instance_taint("  K.send(m, X)")).to eq({})
    end

    it "taints nothing for a `send` that passes no argument beside the name" do
      expect(instance_taint("  send(m)")).to eq({})
      expect(instance_taint("  send")).to eq({})
    end

    # `MixinAccumulator#class_body_scope` answers for the calls whose `self` is the body's class.
    it "taints only a call written where `self` is the class" do
      expect(instance_taint("  send(m, X)", register: false)).to eq({})
      expect(instance_taint("  def a; send(m, X); end")).to eq({})
      expect(instance_taint("  def self.a; send(m, X); end")).to eq("C" => { include: unnamed })
      expect(instance_taint("  foo { send(m, X) }")).to eq("C" => { include: unnamed })
    end

    describe "a local that holds the name" do
      it "taints nothing when the local is bound only to literals that name no mixin of the kinds" do
        expect(instance_taint("  m = :attr_reader\n  send(m, :x)")).to eq({})
        expect(instance_taint("  m = :a\n  m = 'b'\n  send(m, X)")).to eq({})
      end

      it "taints when one of the literals names a mixin of the kinds, as a Symbol or a String" do
        expect(instance_taint("  m = :include\n  send(m, X)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  m = :a\n  m = 'prepend'\n  send(m, X)")).to eq("C" => { include: unnamed })
      end

      it "reads the names against the kinds it is handed" do
        source = "class C\n  m = :include\n  send(m, X)\nend\n"

        expect(taint(source, extend_kinds, :extend)).to eq({})
        expect(taint(source.sub(":include", ":extend"), extend_kinds, :extend)).to eq("C" => { extend: unnamed })
        expect(taint(source.sub(":include", ":extend"), instance_kinds, :include)).to eq({})
      end

      it "taints when the local is bound to anything that is no name literal" do
        expect(instance_taint("  m = foo\n  send(m, X)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  m = :a\n  m = foo\n  send(m, X)")).to eq("C" => { include: unnamed })
      end

      it "reads the writes of that local alone" do
        expect(instance_taint("  n = :include\n  m = :a\n  send(m, X)")).to eq({})
      end

      # Beside a literal write, too: the local may then hold what the other binding gave it.
      it "taints when a local with a literal write is also bound by an operator write or a target" do
        ["m ||= :b", "m += 1", "m, n = :x, :y"].each do |binding|
          expect(instance_taint("  m = :a\n  #{binding}\n  send(m, X)")).to eq("C" => { include: unnamed }), binding
        end
      end

      it "taints when the local has another binding: an operator write, a target or a parameter" do
        expect(instance_taint("  m ||= :a\n  send(m, X)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  m, n = :a, :b\n  send(m, X)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  def self.x(m)\n    send(m, X)\n  end")).to eq("C" => { include: unnamed })
        expect(instance_taint("  def self.x(m = :a)\n    send(m, X)\n  end")).to eq("C" => { include: unnamed })
        expect(instance_taint("  m = :a\n  foo { |m| send(m, X) }")).to eq("C" => { include: unnamed })
        expect(instance_taint("  m = :a\n  foo { |x; m| send(m, X) }")).to eq("C" => { include: unnamed })
      end

      it "taints when the name is no local, or a local with no write in the scope" do
        expect(instance_taint("  send(@m, X)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  def z; m = :a; end\n  send(m, X)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  foo { send(_1, X) }")).to eq("C" => { include: unnamed })
      end

      it "reads the locals of the `def self.` the call sits in" do
        expect(instance_taint("  def self.x\n    m = :a\n    send(m, X)\n  end")).to eq({})
        expect(instance_taint("  def self.x\n    m = :include\n    send(m, X)\n  end"))
          .to eq("C" => { include: unnamed })
      end

      # A nested `def` or declaration opens a scope of its own: a write there is another local.
      it "does not read a write inside a nested `def`, `class`, `module` or `class <<`" do
        ["def z; m = :include; end", "class D; m = :include; end", "module D; m = :include; end",
         "class << self; m = :include; end"].each do |nested|
          expect(instance_taint("  m = :a\n  #{nested}\n  send(m, X)")).to eq({}), nested
        end
      end

      it "reads a write inside a block, which shares the scope's locals" do
        expect(instance_taint("  m = :a\n  foo { m = :include }\n  send(m, X)")).to eq("C" => { include: unnamed })
      end
    end

    describe "a name with an interpolation" do
      it "taints nothing when a literal part is in no mixin's name" do
        expect(instance_taint("  send(\"\#{x}_from_params\", 1)")).to eq({})
        expect(instance_taint("  send(:\"\#{x}_y\", M)")).to eq({})
        expect(instance_taint("  m = \"\#{x}_y\"\n  send(m, M)")).to eq({})
      end

      it "taints when every literal part is in a mixin's name, or there is none" do
        expect(instance_taint("  send(\"in\#{x}\", M)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  send(:\"\#{x}clude\", M)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  send(\"\#{x}\", M)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  m = \"\#{x}tend\"\n  send(m, M)")).to eq("C" => { include: unnamed })
      end

      it "reads a write of such a name beside a literal write as a write of any name, or of none" do
        expect(instance_taint("  m = :a\n  m = \"\#{x}tend\"\n  send(m, M)")).to eq("C" => { include: unnamed })
        expect(instance_taint("  m = :a\n  m = \"\#{x}_y\"\n  send(m, M)")).to eq({})
      end
    end

    describe "the first parameter of an iterator's block (#3024)" do
      it "reads the elements of a literal array as the names" do
        expect(instance_taint("  %i[a b].each { |m| send(m, X) }")).to eq({})
        expect(instance_taint("  %i[include extend].each { |m| send(m, X) }")).to eq("C" => { include: unnamed })
      end

      it "reads `each`, `each_with_index` and `map`, and no other call" do
        expect(instance_taint("  %w[a b].map { |m| send(m, X) }")).to eq({})
        expect(instance_taint("  %i[a b].each_with_index { |m, i| send(m, X) }")).to eq({})
        expect(instance_taint("  %i[a b].select { |m| send(m, X) }")).to eq("C" => { include: unnamed })
      end

      it "reads the first parameter alone, and only a plain one" do
        expect(instance_taint("  %i[a b].each_with_index { |i, m| send(m, X) }")).to eq("C" => { include: unnamed })
        expect(instance_taint("  %i[a b].each { |(m, k)| send(m, X) }")).to eq("C" => { include: unnamed })
        expect(instance_taint("  %i[a b].each { |m, n = 1| send(m, X) }")).to eq({})
      end

      it "taints when an element is no name literal, or the receiver is no array it can read" do
        expect(instance_taint("  [x, :a].each { |m| send(m, X) }")).to eq("C" => { include: unnamed })
        expect(instance_taint("  x.each { |m| send(m, X) }")).to eq("C" => { include: unnamed })
        expect(instance_taint("  m = :a\n  [x].each { |m| send(m, X) }")).to eq("C" => { include: unnamed })
      end

      it "reads an iterator whose first parameter is another local as any other node" do
        expect(instance_taint("  m = :a\n  %i[include].each { |x| send(m, X) }")).to eq({})
      end

      # `|_m, _m = 1|`: the later binding wins, so the first is not the element.
      it "does not read a first parameter another parameter of the block binds again" do
        expect(instance_taint("  %i[a b].each { |_m, _m = 1| send(_m, X) }")).to eq("C" => { include: unnamed })
      end

      it "reads a bare constant the scope assigns a literal array once" do
        expect(instance_taint("  KINDS = %i[a b]\n  KINDS.each { |m| send(m, X) }")).to eq({})
        expect(instance_taint("  KINDS = %i[a include]\n  KINDS.each { |m| send(m, X) }"))
          .to eq("C" => { include: unnamed })
      end

      it "taints for a constant that is unwritten, written twice, written otherwise or no array" do
        ["", "KINDS = %i[a b]\n  KINDS = %i[c]", "KINDS ||= %i[a b]", "KINDS = %i[a b]\n  KINDS ||= %i[c]",
         "KINDS = foo", "class D; KINDS = %i[a]; end", "A::KINDS = %i[a]"].each do |writes|
          expect(instance_taint("  #{writes}\n  KINDS.each { |m| send(m, X) }"))
            .to eq("C" => { include: unnamed }), writes
        end
      end

      it "counts the writes of that bare constant alone" do
        others = "  OTHER = %i[include]\n  KINDS = %i[a b]\n  A::KINDS = %i[include]\n  foo(A::KINDS)\n  KINDS(1)\n"

        expect(instance_taint("#{others}  KINDS.each { |m| send(m, X) }")).to eq({})
      end

      it "reads the constant of an iterator inside an iterator's block" do
        expect(instance_taint("  KINDS = %i[a b]\n  %i[c].each { |m| KINDS.each { |m| send(m, X) } }")).to eq({})
      end

      it "reads only a bare constant: a qualified one may be any array" do
        expect(instance_taint("  KINDS = %i[a]\n  A::KINDS.each { |m| send(m, X) }")).to eq("C" => { include: unnamed })
      end

      it "still reads every other binding of the local in the receiver, the arguments and the body" do
        expect(instance_taint("  m = :include\n  %i[a b].each { |m| send(m, X) }")).to eq("C" => { include: unnamed })
        expect(instance_taint("  %i[a b].each { |m| m = foo; send(m, X) }")).to eq("C" => { include: unnamed })
        expect(instance_taint("  %i[a b].each { |m| m = :include; send(m, X) }")).to eq("C" => { include: unnamed })
        expect(instance_taint("  %i[a b].each { |m| m = :c; send(m, X) }")).to eq({})
      end

      it "reads a block that does not bind the local, or a block argument, as any other node" do
        expect(instance_taint("  m = :a\n  %i[include].each { send(m, X) }")).to eq({})
        expect(instance_taint("  m = :a\n  %i[include].each(&blk)\n  send(m, X)")).to eq({})
      end
    end

    describe "a hook parameter's `send`" do
      # The call alone, in no class body the accumulator knows.
      def bare_hook_taint(current_class, kinds, side, hook: true, body: "base.send(meth, M)", **)
        node = hook_call(body, :send)
        with_accumulator(hook: hook) do |accumulator|
          described_class.taint_computed_mixin_send(node, current_class, accumulator, kinds, side, **)
        end.last
      end

      def hook_taint(body, kinds, side, **)
        taint("module C\n  def self.included(base)\n#{body}\n  end\nend\n", kinds, side, hook: true, **)
      end

      it "taints wherever the hook is written, with the unnamed marker on the instance side" do
        expect(bare_hook_taint("C", instance_kinds, :include)).to eq("C" => { include: unnamed })
      end

      it "taints nothing for the same call outside the hook" do
        expect(bare_hook_taint("C", instance_kinds, :include, hook: false)).to eq({})
      end

      # With no class body to read the local in, the name may be any.
      it "does not read a local that holds the name where no class body is known" do
        expect(bare_hook_taint("C", instance_kinds, :include, body: "m = :attr\n  base.send(m, M)"))
          .to eq("C" => { include: unnamed })
      end

      it "taints the side it is asked for, whatever kinds it is handed, and the instance side too in `class << self`" do
        expect(bare_hook_taint("C", extend_kinds, :extend)).to eq("C" => { extend: wildcard })
        expect(bare_hook_taint("C", extend_kinds, :extend, in_singleton: true))
          .to eq("C" => { extend: wildcard, include: unnamed })
      end

      it "reads the names a local holds: nothing for no mixin's, the order alone for `extend`" do
        expect(hook_taint("    m = :attr\n    base.send(m, M)", instance_kinds, :include)).to eq({})
        expect(hook_taint("    m = :extend\n    base.send(m, M)", instance_kinds, :include))
          .to eq("C" => { include: wildcard })
      end

      it "lists the unnamed marker on the instance side when the name may be `include` or `prepend`" do
        expect(hook_taint("    m = :include\n    base.send(m, M)", instance_kinds, :include))
          .to eq("C" => { include: unnamed })
        expect(hook_taint("    base.send(m, M)", instance_kinds, :include)).to eq("C" => { include: unnamed })
      end

      it "lists it on the instance side alone when it taints both" do
        expect(hook_taint("    m = :prepend\n    base.send(m, M)", extend_kinds, :extend, in_singleton: true))
          .to eq("C" => { extend: wildcard, include: unnamed })
        expect(hook_taint("    m = :extend\n    base.send(m, M)", extend_kinds, :extend, in_singleton: true))
          .to eq("C" => { extend: wildcard, include: wildcard })
      end
    end
  end

  describe ".hook_def_params" do
    def params(source) = described_class.hook_def_params(parse(source).statements.body.first)

    it "lists the required and optional parameters of a hook `def`" do
      expect(params("def self.included(base, opt = 1, *rest, key:, &blk); end\n")).to eq(%i[base opt])
    end

    it "answers an empty list for a hook with no parameter" do
      expect(params("def included; end\n")).to eq([])
    end

    it "reads `included`, `extended`, `prepended` and `inherited`, and no other `def`" do
      %w[included extended prepended inherited].each do |name|
        expect(params("def #{name}(base); end\n")).to eq([:base]), name
      end
      expect(params("def method_added(name); end\n")).to be_nil
    end

    it "skips a parameter that has no name" do
      expect(params("def included((a, b), c); end\n")).to eq([:c])
    end

    it "answers nil for what is no `def`" do
      expect(params("included(base)\n")).to be_nil
      expect(described_class.hook_def_params(nil)).to be_nil
    end
  end

  describe ".taint_opaque_eval" do
    def taint(node, current_class = "C", hook: false)
      with_accumulator(hook: hook) do |accumulator|
        described_class.taint_opaque_eval(node, current_class, accumulator)
      end.last
    end

    def eval_call(source, name = :class_eval) = call("#{source}\n", name)

    it "taints both sides of the enclosing class for an eval block on a receiver nothing names that mixes in" do
      expect(taint(eval_call("x.class_eval { include B }"))).to eq("C" => { include: unnamed, extend: wildcard })
    end

    it "reads every eval-family call, with either block form" do
      %i[class_eval module_eval class_exec module_exec instance_eval instance_exec].each do |name|
        expect(taint(eval_call("x.#{name} { include B }", name)))
          .to eq("C" => { include: unnamed, extend: wildcard }), name.to_s
      end
      expect(taint(eval_call("x.class_eval do\n  include B\nend"))).to eq("C" => { include: unnamed, extend: wildcard })
    end

    it "taints nothing with no enclosing class, no block, or a call that is no eval" do
      expect(taint(eval_call("x.class_eval { include B }"), nil)).to eq({})
      expect(taint(eval_call("x.class_eval(&blk)"))).to eq({})
      expect(taint(eval_call("x.class_eval"))).to eq({})
      expect(taint(eval_call("x.tap { include B }", :tap))).to eq({})
    end

    # The walks record what such a block mixes in: the enclosing class's, or the class the constant names.
    it "taints nothing for a block on the lexical self, or on a constant" do
      expect(taint(eval_call("class_eval { include B }"))).to eq({})
      expect(taint(eval_call("self.class_eval { include B }"))).to eq({})
      expect(taint(eval_call("K.class_eval { include B }"))).to eq({})
      expect(taint(eval_call("A::K.class_eval { include B }"))).to eq({})
    end

    it "reads a constant path through a base nothing names as a receiver nothing names" do
      expect(taint(eval_call("x::K.class_eval { include B }"))).to eq("C" => { include: unnamed, extend: wildcard })
    end

    it "taints nothing for a block that mixes nothing in" do
      expect(taint(eval_call("obj.instance_eval { foo }", :instance_eval))).to eq({})
      expect(taint(eval_call("obj.instance_eval { }", :instance_eval))).to eq({})
      expect(taint(eval_call("obj.class_eval { send(m, M) }"))).to eq({})
    end

    it "finds a mixin call anywhere in the block, in its `send` spelling too" do
      expect(taint(eval_call("x.class_eval { if y then [1].each { prepend M } end }")))
        .to eq("C" => { include: unnamed, extend: wildcard })
      expect(taint(eval_call("x.class_eval { send(:include, M) }")))
        .to eq("C" => { include: unnamed, extend: wildcard })
    end

    # The set is unknown only where the block may mix into the class itself (#2991).
    it "taints the order alone when the block mixes into no `self`: an `extend`, or a call on another receiver" do
      expect(taint(eval_call("x.class_eval { extend M }"))).to eq("C" => { include: wildcard, extend: wildcard })
      expect(taint(eval_call("x.class_eval { send(:extend, M) }")))
        .to eq("C" => { include: wildcard, extend: wildcard })
      expect(taint(eval_call("x.class_eval { K.include M }"))).to eq("C" => { include: wildcard, extend: wildcard })
    end

    it "reads a `self.` `include` in the block as a receiverless one" do
      expect(taint(eval_call("x.class_eval { self.include M }")))
        .to eq("C" => { include: unnamed, extend: wildcard })
    end

    it "taints the order alone for the block of a `singleton_class` receiver" do
      expect(taint(eval_call("x.singleton_class.class_eval { include M }")))
        .to eq("C" => { include: wildcard, extend: wildcard })
    end

    it "taints for a hook parameter's block whatever it holds, with the unnamed marker" do
      expect(taint(hook_call("base.class_eval { foo }", :class_eval), hook: true))
        .to eq("C" => { include: unnamed, extend: wildcard })
      expect(taint(hook_call("base.class_eval { foo }", :class_eval))).to eq({})
    end

    it "reads a `singleton_class` chain off a hook's parameter as the parameter" do
      expect(taint(hook_call("base.singleton_class.class_eval { foo }", :class_eval), hook: true))
        .to eq("C" => { include: unnamed, extend: wildcard })
    end
  end

  describe ".prepend_call_receiver" do
    def receiver(source, prefix = []) = described_class.prepend_call_receiver(call(source, :prepend), prefix)

    it "names the class a constant receiver names at the top level, as written" do
      expect(receiver("Base.prepend(M)\n")).to eq("Base")
      expect(receiver("A::B.prepend(M)\n")).to eq("A::B")
    end

    it "answers nil for a receiver that names no static class" do
      expect(receiver("self.prepend(M)\n", ["A"])).to be_nil
      expect(receiver("prepend(M)\n", ["A"])).to be_nil
      expect(receiver("obj.prepend(M)\n", ["A"])).to be_nil
      expect(receiver("x::K.prepend(M)\n", ["A"])).to be_nil
    end

    it "names a rooted receiver from the top level wherever it is written" do
      expect(receiver("module Api; class B; end; ::B.prepend(M); end\n", ["Api"])).to eq("B")
      expect(receiver("module Api; ::A::B.prepend(M); end\n", ["Api"])).to eq("A::B")
    end

    it "resolves an unqualified receiver through the nesting, innermost first, by what the file declares" do
      outer = "module Api\n  class C; end\n  module V1\n    C.prepend(T)\n  end\nend\n"
      both = "module Api\n  class C; end\n  module V1\n    class C; end\n    C.prepend(T)\n  end\nend\n"

      expect(receiver("module Api\n  class C; end\n  C.prepend(T)\nend\n", ["Api"])).to eq("Api::C")
      expect(receiver(outer, %w[Api V1])).to eq("Api::C")
      expect(receiver(both, %w[Api V1])).to eq("Api::V1::C")
      expect(receiver("module Api\n  K = Class.new\n  K.prepend(T)\nend\n", ["Api"])).to eq("Api::K")
    end

    it "resolves a path by its first segment" do
      expect(receiver("module Api\n  class C; class D; end; end\n  C::D.prepend(T)\nend\n", ["Api"]))
        .to eq("Api::C::D")
    end

    it "keeps the name as written when no rung of the nesting declares it" do
      expect(receiver("module Api\n  C.prepend(T)\nend\n", ["Api"])).to eq("C")
    end
  end

  describe ".meta_new_mixin_owner" do
    def owner(source, prefix, cref, *base)
      described_class.meta_new_mixin_owner(parse(source).statements.body.first, prefix, cref, *base)
    end

    it "names the class a constant write creates, under the prefix it is written in" do
      expect(owner("K = Class.new { include T }\n", [], false)).to eq("K")
      expect(owner("K = Class.new { include T }\n", ["A"], false)).to eq("A::K")
      expect(owner("B::K = Class.new { include T }\n", ["A"], false)).to eq("A::B::K")
      expect(owner("::K = Class.new { include T }\n", ["A"], false)).to eq("K")
    end

    # An `||=` block still runs on the class the write names when it runs.
    it "names the class of an or-write as of a plain write" do
      expect(owner("K ||= Class.new { include I }\n", ["A"], false)).to eq("A::K")
      expect(owner("B::K ||= Class.new { include I }\n", ["A"], false)).to eq("A::B::K")
    end

    it "names nothing for a bare write below an unnameable cref, and a path write as it is written" do
      expect(owner("K = Class.new { include T }\n", ["A"], true)).to be_nil
      expect(owner("K ||= Class.new { include T }\n", ["A"], true)).to be_nil
      expect(owner("B::K = Class.new { include T }\n", ["A"], true)).to eq("A::B::K")
      expect(owner("::K = Class.new { include T }\n", ["A"], true)).to eq("K")
    end

    it "anchors a `self::` write on the rebound self it is handed" do
      expect(owner("self::K = Class.new { include T }\n", ["A"], false)).to eq("A::K")
      expect(owner("self::K = Class.new { include T }\n", ["A"], false, ["C"])).to eq("C::K")
      expect(owner("self::K = Class.new { include T }\n", ["A"], true, ["C"])).to eq("C::K")
    end

    it "names nothing for a `self::` write below an unnameable cref with no self a name reaches" do
      expect(owner("self::K = Class.new { include T }\n", ["A"], true)).to be_nil
      expect(owner("self::K = Class.new { include T }\n", ["A"], true, [])).to be_nil
    end

    it "names nothing for a write through a base nothing names" do
      expect(owner("x::K = Class.new { include T }\n", ["A"], false)).to be_nil
      expect(owner("x::K = Class.new { include T }\n", ["A"], true)).to be_nil
    end
  end

  # What another file of `lib/` calls: the include walk (`MixinTables`) and the extend walk left in `scope_indexer.rb`
  # each call all eight. A ninth name here is a new way into the module. Its three constants are private.
  it "exposes the eight functions both walks call, and no constant" do
    expect(described_class.singleton_methods(false).sort)
      .to eq(%i[hook_def_params meta_new_mixin_owner mixin_effects prepend_call_receiver program_statements
                taint_computed_mixin_send taint_opaque_eval taint_unrecorded_mixin])
    expect(described_class.constants(false)).to eq([])
    expect(private_constants.select { |name| described_class.const_defined?(name, false) }).to eq(private_constants)
    expect { described_class::HOOK_DEFS }.to raise_error(NameError, /private constant/)
  end

  it "leaves none of its 31 functions on ScopeIndexer, public or private, and none of its three constants" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(31)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
    expect(private_constants.select { |name| indexer.const_defined?(name, false) }).to eq([])
  end

  # The #3318 cut-off counts the functions a moved cluster calls back in what stays, and allows four. This one calls
  # three, recognisers the other walkers ask too: whether a mixin argument names nothing, the lexical `self`, and what
  # a call mixes in.
  it "calls three functions of the indexer, at four sites" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/mixin_effects.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == "ScopeIndexer"
    end

    expect(calls).to eq(%i[opaque_mixin_argument? lexical_self_receiver? mixin_call_view mixin_call_view])
  end

  describe "its callers" do
    # One snippet, both walks: each asks the effects of every call, the three taints, the hook's parameters and the
    # owner of the class-creating write, and files what it is answered on its own side.
    it "is what the include walk and the extend walk both ask" do
      source = <<~RUBY
        class C
          include helper
          extend(*MODS)
          send(m, X)
          x.class_eval { include B }
        end
        module Hooked
          def self.included(base)
            base.include M
          end
        end
        K = Class.new { include(*A); extend(*B) }
        Base.prepend(*P)
        Base.extend(*E)
      RUBY
      include_walk = indexer::MixinTables.mixin_tables(parse(source)).fetch(:unpositioned)
      extend_walk = indexer.extend_tables(parse(source)).fetch(:unpositioned)

      expect(include_walk).to eq("C" => { include: unnamed, extend: wildcard }, "Hooked" => { include: unnamed },
                                 "K" => { include: unnamed }, "Base" => { include: unnamed })
      expect(extend_walk).to eq("C" => { extend: unnamed, include: unnamed }, "Hooked" => { extend: wildcard },
                                "K" => { extend: unnamed }, "Base" => { extend: unnamed })
    end

    it "is the program statements both walks mark as direct" do
      source = "class C\n  include M\n  extend E\nend\n"

      expect(indexer::MixinTables.mixin_tables(parse(source))).to include(includes: { "C" => ["M"] }, unpositioned: {})
      expect(indexer.extend_tables(parse(source))).to eq(extends: { "C" => ["E"] }, unpositioned: {})
    end
  end

  # The module reads four of the indexer's constants and calls three of its functions, which `scope_indexer.rb`
  # defines: the file requires what else it names, and until the indexer has loaded it answers where it reaches none
  # of the seven.
  def alone_probe
    <<~RUBY
      require "rigor/inference/scope_indexer/mixin_effects"
      effects = Rigor::Inference::ScopeIndexer::MixinEffects
      accumulator = Class.new(Hash) do
        def hook_local?(name) = name == :base
        def taint(owner, side, unnamed: false) = (self[owner] ||= []) << [side, unnamed]
        def class_body_scope(_node) = nil
      end
      first = ->(source) { Prism.parse(source).value.statements.body.first }
      hook = ->(body) { first.call("def self.included(base)\\n  \#{body}\\nend\\n").body.body.first }
      try = lambda do |&question|
        question.call
      rescue NameError => e
        [e.class.name, e.name]
      end
      taints = lambda do |&question|
        table = accumulator.new
        answer = try.call { question.call(table) }
        answer.is_a?(Array) && answer.first.is_a?(String) ? answer : table
      end
      answers = [
        effects.program_statements(Prism.parse("x").value).class.name,
        effects.hook_def_params(first.call("def self.included(base, opt = 1); end")),
        effects.prepend_call_receiver(first.call("Base.prepend(M)"), []),
        effects.meta_new_mixin_owner(first.call("K = Class.new { include T }"), ["A"], false),
        effects.mixin_effects(hook.call("base.include M"), :include, [], "C", accumulator.new, in_singleton: false),
        taints.call { |table| effects.taint_unrecorded_mixin(first.call("include x"), :include, [1], [["C", :include]], table) },
        taints.call { |table| effects.taint_unrecorded_mixin(first.call("include"), :include, [], [["C", :include]], table) },
        taints.call { |table| effects.taint_computed_mixin_send(first.call("send(m, X)"), nil, table, [], :include) },
        taints.call { |table| effects.taint_computed_mixin_send(first.call("send(m, X)"), "C", table, [], :include) },
        taints.call { |table| effects.taint_opaque_eval(hook.call("base.class_eval { foo }"), "C", table) },
        taints.call { |table| effects.taint_opaque_eval(first.call("x.class_eval { 1 }"), "C", table) },
        taints.call { |table| effects.taint_opaque_eval(first.call("x.class_eval { foo }"), "C", table) }
      ]
      print [Rigor::Inference::ScopeIndexer.respond_to?(:index), defined?(Rigor::Inference::DeclarationWalk::Rules),
             defined?(Rigor::Source::ConstantPath), defined?(Rigor::Source::NodeWalker),
             Prism::CallNode.method_defined?(:rigor_each_child), answers].inspect
    RUBY
  end

  it "loads without the indexer, with what it names, and answers where it reaches nothing of the indexer" do
    lib = File.join(DeclarationFactSources::REPO_ROOT, "lib")
    out, err, status = RubyRun.capture("-I", lib, "-e", alone_probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, "constant", "constant", "constant", true, ["Prism::StatementsNode", [:base, :opt], ' \
                      '"Base", "A::K", [["C", :include], ["C", :extend]], ' \
                      '["NoMethodError", :opaque_mixin_argument?], ["NameError", :INSTANCE_MIXIN_NAMES], {}, ' \
                      '["NameError", :SEND_CALL_NAMES], {"C" => [[:include, true], [:extend, false]]}, {}, ' \
                      '["NameError", :MIXIN_KINDS]]]')
  end
end
