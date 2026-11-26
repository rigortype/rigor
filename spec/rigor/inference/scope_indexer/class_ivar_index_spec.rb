# frozen_string_literal: true

require "spec_helper"
require "open3"
require "prism"
require "rbconfig"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::ClassIvarIndex` is the class ivar index of one file: per class, the type each
# instance variable holds, joined over the writes the file makes. The examples hand `.build_class_ivar_index` a parsed
# snippet and a scope and read the table back, each type as its description: no index is built and no body evaluated.
# The table of instance `def`s its definite-assignment summary reads is private and reached through `send`. What
# other files and the ancestor chain contribute (`ivar_contributions_spec.rb`), what a signature declares
# (`declared_ivar_type_census_spec.rb`), a write from a declared parameter (`declared_param_ivar_census_spec.rb`) or
# from a constant (`constant_ivar_census_spec.rb`), and what a run makes of the table (`scope_indexer_spec.rb`,
# `spec/integration/`) are pinned where those names say.
RSpec.describe Rigor::Inference::ScopeIndexer::ClassIvarIndex do
  let(:combinator) { Rigor::Type::Combinator }
  let(:empty) { Rigor::Scope.empty }
  let(:indexer) { Rigor::Inference::ScopeIndexer }

  def parse(source) = Prism.parse(source).value

  def described(table) = table.transform_values { |entries| entries.transform_values(&:describe) }

  # The index of a snippet, each type as its description.
  define_method(:seeds) do |source, scope = empty, **options|
    described(described_class.build_class_ivar_index(parse(source), scope, **options))
  end

  # The entries of `C` for a `class C` around `body`.
  define_method(:c) do |body, scope = empty|
    seeds("class C\n#{body}\nend\n", scope).fetch("C", {})
  end

  # A scope that knows `Bar` at two depths, so a `Bar.new` rvalue says which chain it was typed under.
  def bars
    classes = %w[Bar M::Bar].to_h { |name| [name, combinator.singleton_of(name)] }
    empty.with_discovery(empty.discovery.with(discovered_classes: classes))
  end

  # A scope whose environment carries one plugin with the given manifest entries.
  def plugin_scope(**manifest)
    services = Rigor::Plugin::Services.new(reflection: Rigor::Reflection, type: combinator,
                                           configuration: Rigor::Configuration.new)
    plugin = Class.new(Rigor::Plugin::Base) { manifest(id: "ivar-index-spec", version: "0.1.0", **manifest) }
    registry = Rigor::Plugin::Registry.new(plugins: [plugin.new(services: services)])
    Rigor::Scope.empty(environment: Rigor::Environment.new(plugin_registry: registry))
  end

  describe ".build_class_ivar_index" do
    it "answers an empty table for a file that writes no ivar in a class's def, and for a root that is no node" do
      expect(seeds("x = 1\n@a = 1\ndef m; @a = 1; end\nclass C; def r; @a; end; end\n")).to eq({})
      expect(described_class.build_class_ivar_index(nil, empty)).to eq({})
    end

    it "freezes the table and each class's entries" do
      table = described_class.build_class_ivar_index(parse("class C; def a; @a = 1; end; end\n"), empty)

      expect([table.frozen?, table.fetch("C").frozen?]).to eq([true, true])
    end

    it "joins the writes of an ivar over the bodies of a class, and keeps each class's own" do
      source = "class C\ndef a; @a = 1; end\ndef b; @b = :s; @a = \"s\"; end\nend\n" \
               "class D; def a; @a = 2; end; end\nclass C; def c; @b = 3; end; end\n"

      expect(seeds(source)).to eq("C" => { :@a => '"s" | 1', :@b => "3 | :s" }, "D" => { :@a => "2" })
    end

    # #1406 — `rigor sig-gen` passes false: it proposes what the code says.
    it "lets a declaration replace the join unless it is told not to" do
      allow(indexer::DeclaredIvarTypes).to receive(:apply!) do |accumulator, _scope|
        accumulator["C"] = { :@a => combinator.nominal_of("String") }
      end
      source = "class C; def a; @a = 1; end; end\n"

      expect(seeds(source)).to eq("C" => { :@a => "String" })
      expect(seeds(source, empty, declared_ivar_types: false)).to eq("C" => { :@a => "1" })
      expect(indexer::DeclaredIvarTypes).to have_received(:apply!).once.with(Hash, empty)
    end

    # #2170, #2931 — the join of what other files and the ancestor chain contribute is handed the file's own writes
    # as the walk typed them, before the read-before-write `nil`, and without an ivar a singleton-side `def` of the
    # class writes: that write runs on the module object, never on an includer's instance. A mutation the file
    # observes has widened them by then.
    it "hands the contributions join a copy of the writes, a singleton-side def's ivars left out" do
      handed = nil
      allow(indexer::IvarContributions).to receive(:join!) do |accumulator, writes, scope|
        handed = [described(accumulator), described(writes), scope]
      end
      seeds("module M\ndef self.boot; @reg = {}; @own = 1; end\ndef reg; @reg = [1]; end\n" \
            "def use; @late.x; end\ndef set; @late = 1; end\nend\n" \
            "class C; def initialize; @a = [1]; end; def b; @a << 2; end; end\n")

      expect(handed).to eq(
        [{ "M" => { :@reg => "Hash[Dynamic[top], Dynamic[top]] | [1]", :@own => "1", :@late => "1?" },
           "C" => { :@a => "Array[Dynamic[top]]" } },
         { "M" => { :@late => "1" }, "C" => { :@a => "Array[Dynamic[top]]" } }, empty]
      )
    end

    it "widens what the join brought for an ivar the file mutates, as it widened the file's own write" do
      joined = combinator.tuple_of(combinator.constant_of(:joined))
      allow(indexer::IvarContributions).to receive(:join!) do |accumulator, _writes, _scope|
        accumulator["C"].each_key { |ivar| accumulator["C"][ivar] = combinator.union(accumulator["C"][ivar], joined) }
      end

      expect(c("def initialize; @a = [1]; @b = [2]; end\ndef push; @a << 3; end"))
        .to eq(:@a => "Array[Dynamic[top]]", :@b => "[2] | [:joined]")
    end
  end

  describe "a class or module header" do
    it "files a def's writes under the class its header names: nested, compact and rooted" do
      source = "module M\nclass C\ndef a; @a = 1; end\nend\nclass A::B; def b; @b = 2; end; end\n" \
               "class ::R; def r; @r = 3; end; end\ndef m; @m = 4; end\nend\n"

      expect(seeds(source))
        .to eq("M::C" => { :@a => "1" }, "M::A::B" => { :@b => "2" }, "R" => { :@r => "3" }, "M" => { :@m => "4" })
    end

    it "files nothing for a def outside every class, a write in a class body, or a block there" do
      expect(seeds("def m; @a = 1; end\n@b = 2\nclass C\n@c = 3\n[1].each { @d = 4 }\nend\n")).to eq({})
    end

    it "walks the body of a header, never its superclass, and a header with no body is nothing" do
      source = "module M\nclass C < (def helper; @h = 1; end; Base)\ndef a; @a = 1; end\nend\nclass D; end\nend\n"

      expect(seeds(source)).to eq("M::C" => { :@a => "1" })
    end

    # Issue #681 — the chain a compact header pushes is one entry, so a bare `Bar` in it names `::Bar`.
    it "types a body's rvalues under the chain of the header it is in" do
      source = "module M\nclass C\ndef a; @a = Bar.new; end\nend\nend\nclass M::D\ndef b; @b = Bar.new; end\nend\n"

      expect(seeds(source, bars)).to eq("M::C" => { :@a => "M::Bar" }, "M::D" => { :@b => "Bar" })
    end

    it "anchors a `self::` header on the rebound self around it" do
      source = "K = Class.new do\nclass self::Inner; def i; @i = 1; end; end\nend\n" \
               "class C\nclass self::S; def s; @s = 1; end; end\nend\n"

      expect(seeds(source)).to eq("K::Inner" => { :@i => "1" }, "C::S" => { :@s => "1" })
    end

    # The walk asks no rule whether a header's base names anything: it files the body under the name the path renders.
    it "files a header through a base nothing names under the name it renders" do
      expect(seeds("class C\nclass x::D; def d; @d = 1; end; end\nend\nclass y::E; def e; @e = 1; end; end\n"))
        .to eq("C::D" => { :@d => "1" }, "E" => { :@e => "1" })
    end

    # A `self::` header takes the class a block gives `self`; under a block that names none its body names nothing, and
    # neither does a bare header in it.
    it "anchors a `self::` header on the class a block names, and names nothing under a block that names none" do
      named = "class C\nclass << self\n::L = Class.new { class self::In; def m; @a = 1; end; end }\nend\nend\n"
      anonymous = "Class.new { class self::In\nclass Deep; def m; @a = 1; end; end\nend }\n"

      expect(seeds(named)).to eq("L::In" => { :@a => "1" })
      expect(seeds(anonymous)).to eq({})
    end

    # The class-body writes of a header no name reaches are filed nowhere: not under the name a real class renders to.
    it "counts no class-body write of a header no name reaches for the class of the same rendered name" do
      source = "class C\nclass D\ndef w; @x = 1; end\ndef r; @x; end\nend\n" \
               "class << self\nclass D\n@x = 0\nend\nend\nend\n"

      expect(seeds(source)).to eq("C::D" => { :@x => "1?" })
    end

    # #708 — a rooted header resets the prefix and keeps the chain: `Bar` in `class ::R` inside `module M` is `M::Bar`.
    it "types a rooted header's rvalues under the chain around it" do
      expect(seeds("module M\nclass ::R\ndef m; @x = Bar.new; end\nend\nend\n", bars)).to eq("R" => { :@x => "M::Bar" })
    end
  end

  describe "a `class <<` body" do
    it "files nothing for a def, an `attr_writer` or a `define_method` block written directly in it" do
      body = "class << self\ndef s; @s = 1; end\nattr_writer :w\ndefine_method(:d) { @d = 1 }\nend\ndef i; @i = 1; end"

      expect(c(body)).to eq(:@i => "1")
    end

    it "walks its expression in the context around it" do
      source = "class C\nclass << (class D; def d; @d = 1; end; self; end)\ndef s; @s = 1; end\nend\nend\n"

      expect(seeds(source)).to eq("C::D" => { :@d => "1" })
    end

    it "opens a bare header below it ownerless, and a rooted or path header at the name it writes" do
      source = "class C\nclass << self\nclass D; def d; @d = 1; end; end\nclass ::E; def e; @e = 1; end; end\n" \
               "class Other::F; def f; @f = 1; end; end\nend\nend\n"

      expect(seeds(source)).to eq("E" => { :@e => "1" }, "C::Other::F" => { :@f => "1" })
    end

    it "keeps the cref unnameable for the bodies below a bare header" do
      source = "class C\nclass << self\nmodule D\nclass E; def e; @e = 1; end; end\ndef d; @d = 1; end\n" \
               "end\nend\nend\n"

      expect(seeds(source)).to eq({})
    end

    it "keeps it unnameable across a block and a def inside it" do
      source = "class C\nclass << self\n[1].each { def blk; @b = 1; end }\n" \
               "def s; def inner; @i = 1; end; end\nend\nend\n"

      expect(seeds(source)).to eq({})
    end

    it "keeps it unnameable for what the body nests: the parts of a call, an eval block, another `class <<`" do
      source = "class C\nclass << self\n" \
               "Class.new((class D; def d; @d = 1; end; end; Object)) { class E; def e; @e = 1; end; end }\n" \
               "X.class_eval((class F; def f; @f = 1; end; end)) { class G; def g; @g = 1; end; end }\n" \
               "[1].each { K = Class.new { def k; @k = 1; end } }\n" \
               "class << (class H; def h; @h = 1; end; self; end); end\nend\nend\n"

      expect(seeds(source)).to eq({})
    end
  end

  describe "a constant write that creates a class" do
    it "files the block's defs under the class the write names: a bare write, a path write and an or-write" do
      source = "K = Class.new do\ndef m; @x = 1; end\nend\nclass C\nL = Class.new(Base) { def m; @y = 2; end }\n" \
               "M::N = Struct.new(:a) { def m; @z = 3; end }\nO ||= Class.new { def m; @o = 4; end }\n" \
               "M::Q ||= Class.new { def m; @q = 5; end }\nend\n"

      expect(seeds(source)).to eq("K" => { :@x => "1" }, "C::L" => { :@y => "2" }, "C::M::N" => { :@z => "3" },
                                  "C::O" => { :@o => "4" }, "C::M::Q" => { :@q => "5" })
    end

    it "keeps a header inside the block lexical, and its rvalues typed under the cref around the write" do
      source = "module M\nK = Class.new do\nclass Inner; def i; @i = Bar.new; end; end\n" \
               "def m; @x = Bar.new; end\nend\nend\n"

      expect(seeds(source, bars)).to eq("M::Inner" => { :@i => "M::Bar" }, "M::K" => { :@x => "M::Bar" })
    end

    it "keeps the class the write names through what the block nests: a block, a conditional, a bare eval" do
      source = "K = Class.new do\n[1].each { def m; @x = 1; end }\nif cond\ndef n; @y = 2; end\nend\n" \
               "class_eval { def own; @o = 3; end }\nself::Inner.class_eval { def i; @i = 4; end }\nend\n"

      expect(seeds(source)).to eq("K" => { :@x => "1", :@y => "2", :@o => "3" }, "K::Inner" => { :@i => "4" })
    end

    it "walks the call's receiver and arguments in the context around the write" do
      body = "K = Class.new((def helper; @h = 1; end; Object)) { def m; @x = 1; end }"

      expect(seeds("class C\n#{body}\nend\n")).to eq("C" => { :@h => "1" }, "C::K" => { :@x => "1" })
    end

    it "walks a write that creates no class, and one with no block, as any other node" do
      expect(c("X = (def helper; @h = 1; end; 1)\nY = Class.new((def other; @o = 2; end; Object))"))
        .to eq(:@h => "1", :@o => "2")
    end

    it "files nothing for a bare write below `class <<`, and the named class for a path write there" do
      source = "class C\nclass << self\nK = Class.new { def k; @k = 1; end }\n" \
               "::L = Class.new((def helper; @h = 1; end; Object)) { def l; @l = 1; end }\nend\nend\n"

      expect(seeds(source)).to eq("L" => { :@l => "1" })
    end

    it "hands the block's own `class <<` and nested writes the class it names" do
      source = "K = Class.new do\nclass << self\ndef s; @s = 1; end\nend\n" \
               "self::W = Class.new { def w; @w = 1; end }\nattr_writer :a\nend\n"

      expect(seeds(source)).to eq("K::W" => { :@w => "1" }, "K" => { :@a => "Dynamic[top]" })
    end

    it "keeps the unnameable cref below `class <<` for a header in the call's arguments, and for one in the block" do
      source = "class C\nclass << self\nK = Class.new((class In; def m; @a = 1; end; end; Object)) { }\n" \
               "::L = Class.new { class In2; def m; @b = 1; end; end }\nend\nend\n"

      expect(seeds(source)).to eq({})
    end

    # The write is answered for whatever its block's body is. A body with a `rescue` is not walked a second time as a
    # block no write names, which would hold an `op=` write of a header in it twice.
    it "walks a block whose body has a `rescue` once" do
      source = "K = Class.new do\nclass In; def a; @a = [0]; end; def b; @a += [:s]; end; end\n" \
               "rescue StandardError\nnil\nend\n"

      expect(seeds(source)).to eq("In" => { :@a => "[0, :s] | [0]" })
    end
  end

  describe "a class-creating call no write names" do
    it "walks the block ownerless, and the call's receiver and arguments in the context around it" do
      body = "Class.new { def m; @x = 1; end; attr_writer :w }\n" \
             "Class.new((def helper; @h = 1; end; Object)) { def m; @y = 1; end }\n" \
             "Struct.new(:a) { def m; @z = 1; end }"

      expect(c(body)).to eq(:@h => "1")
    end

    it "keeps a header inside the block lexical, and walks a call with no block as any other" do
      source = "class C\nClass.new do\nclass Inner; def i; @i = 1; end; end\nend\n" \
               "Class.new((def helper; @h = 1; end; Object))\nend\n"

      expect(seeds(source)).to eq("C::Inner" => { :@i => "1" }, "C" => { :@h => "1" })
    end

    # The call is answered for whatever its block's body is: a body with a `rescue` is not walked a second time, as
    # a block of the class around the call.
    it "walks a block whose body has a `rescue` once, ownerless" do
      expect(c("Class.new do\ndef m; @a = 1; end\nrescue StandardError\nnil\nend")).to eq({})
    end

    it "walks a header inside the block with the walk's tables: mutations, evidence, initializers, effects" do
      source = "class C\nClass.new do\nclass In\ndef helper; @h = [1]; @h << 2; @t = nil; setup; end\n" \
               "def initialize; @i = 1; end\ndef rd; @r; end\ndef setup; @t = 1; end\ndef use; @i; end\n" \
               "def w; @r = 1; end\nend\nend\nend\n"

      expect(seeds(source))
        .to eq("C::In" => { :@h => "Array[Dynamic[top]]", :@i => "1", :@t => "1", :@r => "1?" })
    end
  end

  describe "a block that rebinds `self`" do
    it "files an eval-family block's defs under its receiver, and under the class around it for `self` or none" do
      source = "class X; end\nclass C\nX.class_eval { def m; @a = 1; end }\nclass_eval { def o; @c = 1; end }\n" \
               "self.class_exec { def q; @e = 1; end }\nx.class_eval { def p; @d = 1; end }\nend\n" \
               "X.module_eval { def n; @b = 2; end }\nclass_eval { def top; @t = 1; end }\n"

      expect(seeds(source)).to eq("X" => { :@a => "1", :@b => "2" }, "C" => { :@c => "1", :@e => "1" })
    end

    # `X.instance_eval { def m; @x = 1 }` defines a singleton method of `X`: the write is `X`'s own ivar, typed as a
    # `def self.m` body's is.
    it "types an `instance_eval` block's defs on the receiver's singleton side" do
      source = "class X; end\nX.instance_eval { def n; @b = self; end }\nX.instance_exec { def o; @c = self; end }\n" \
               "X.class_eval { def m; @a = self; end }\n"

      expect(seeds(source)).to eq("X" => { :@b => "singleton(X)", :@c => "singleton(X)", :@a => "X" })
    end

    # The side is handed on to what the block nests and to the parts of the calls in it, but for the parts of a
    # class-creating write and the expression of a `class <<`, whose arms are not handed it.
    it "keeps the singleton side of an `instance_eval` block through a block and a call's parts, with two exceptions" do
      source = "class X; end\nclass Y; end\nX.instance_eval do\n[1].each { def a; @a = self; end }\n" \
               "Class.new((def c; @c = self; end; Object)) { def anon; @n = self; end }\n" \
               "Y.class_eval((def d; @d = self; end)) { def y; @y = self; end }\n" \
               "K = Class.new((def b; @b = self; end; Object)) { def k; @k = self; end }\n" \
               "class << (def e; @e = self; end; self); end\nclass Z; def z; @z = self; end; end\nend\n"

      expect(seeds(source)).to eq(
        "X" => { :@a => "singleton(X)", :@c => "singleton(X)", :@d => "singleton(X)", :@b => "X", :@e => "X" },
        "Y" => { :@y => "Y" }, "K" => { :@k => "K" }, "Z" => { :@z => "Z" }
      )
    end

    it "walks the call's receiver and arguments in the context around it" do
      source = "class X; end\nclass C\nX.class_eval((def helper; @h = 1; end)) { def m; @a = 1; end }\nend\n"

      expect(seeds(source)).to eq("C" => { :@h => "1" }, "X" => { :@a => "1" })
    end

    it "anchors a `self::` header in the block on the receiver, and keeps a bare one lexical" do
      source = "class X; end\nmodule M\nX.class_eval do\nclass self::Inner; def i; @i = 1; end; end\n" \
               "class Plain; def p; @p = 1; end; end\nend\nend\n"

      expect(seeds(source)).to eq("X::Inner" => { :@i => "1" }, "M::Plain" => { :@p => "1" })
    end

    it "walks a call with no block, a block argument or an ordinary block as any other node" do
      body = "X.class_eval(src)\nX.class_eval(&blk)\n[1].each { def m; @a = 1; end }\nfoo(def n; @b = 2; end)"

      expect(c(body)).to eq(:@a => "1", :@b => "2")
    end

    it "leaves the cref unnameable below `class <<`: a bare eval's defs are filed nowhere, a named receiver's are" do
      source = "class X; end\nclass C\nclass << self\nclass_eval { def a; @a = 1; end }\n" \
               "X.class_eval { def b; @b = 1; end }\nend\nend\n"

      expect(seeds(source)).to eq("X" => { :@b => "1" })
    end

    it "walks a block whose body has a `rescue` once, under its receiver" do
      source = "class X; end\nclass D\nX.class_eval do\ndef m; @a = 1; end\nrescue StandardError\nnil\nend\nend\n"

      expect(seeds(source)).to eq("X" => { :@a => "1" })
    end

    it "names nothing for a `self::` receiver in a header no name reaches" do
      source = "class C\nclass << self\nclass D\nself::Y.class_eval { def m; @a = 1; end }\nend\nend\nend\n"

      expect(seeds(source)).to eq({})
    end
  end

  describe "a def body" do
    it "types `self` as the instance, and as the class in a `def self.` or a def on the class's own name" do
      body = "def i; @i = self; end\ndef self.s; @s = self; end\ndef C.t; @t = self; end"

      expect(c(body)).to eq(:@i => "C", :@s => "singleton(C)", :@t => "singleton(C)")
    end

    # Issue #3155 — `def String.q` in `class C` writes the ivars of another object.
    it "files nothing for a def on another receiver, a def with no body, or a def below no class" do
      expect(seeds("class C\ndef String.q; @q = 1; end\ndef other.r; @r = 1; end\ndef e; end\nend\n" \
                   "def t; @t = 1; end\n"))
        .to eq({})
    end

    it "names a def's own class by the last segments of a path receiver" do
      source = "module M\nclass C\ndef C.a; @a = self; end\nend\nend\n"

      expect(seeds(source)).to eq("M::C" => { :@a => "singleton(M::C)" })
    end

    it "stops at a def or a class nested in the body, and walks its blocks" do
      body = "def m\n@a = 1\ndef inner; @b = 2; end\nclass Local; @c = 3; def x; @d = 4; end; end\n" \
             "[1].each { @e = 5 }\n-> { @f = 6 }\nend"

      expect(c(body)).to eq(:@a => "1", :@e => "5", :@f => "6")
    end

    # #1154 — an `@x = x` from a declared parameter records the parameter's declared type, for an instance def.
    it "takes the type a declared parameter credits a write with, on the instance side alone" do
      allow(indexer::DeclaredParamWrites).to receive(:collect) do |def_node, _class_name, _scope|
        {}.compare_by_identity.tap { |credited| credited[def_node.body.body.first] = combinator.nominal_of("String") }
      end

      expect(c("def a(x); @a = x; @b = x; end\ndef self.s(x); @s = x; end"))
        .to eq(:@a => "String", :@b => "Dynamic[top]", :@s => "Dynamic[top]")
      expect(indexer::DeclaredParamWrites).to have_received(:collect).once
    end

    it "takes that credit for a write anywhere in the body: in a branch, a predicate, a guarded body or a block" do
      allow(indexer::DeclaredParamWrites).to receive(:collect) do |def_node, _class_name, _scope|
        writes = Rigor::Source::NodeWalker.each(def_node.body).grep(Prism::InstanceVariableWriteNode)
        writes.to_h { |write| [write, combinator.nominal_of("String")] }.compare_by_identity
      end
      body = "def a(x)\nif (@p = x)\n@t = x\nelse\n@e = x\nend\n@g = x unless @g\n[1].each { @b = x }\nend"

      expect(c(body)).to eq(:@p => "String", :@t => "String", :@e => "String", :@g => "String?", :@b => "String")
    end

    # #2291 — an `@x = LIT` write reads the file's constant table.
    it "takes a constant rvalue's type from the file's own constant table" do
      expect(seeds("class K\nLIT = [:a, :b].freeze\ndef initialize = @x = LIT\ndef other = @y = MISSING\nend\n"))
        .to eq("K" => { :@x => "[:a, :b]", :@y => "Dynamic[top]" })
    end

    # #2499 — an empty literal is never proof of emptiness.
    it "erases an empty literal's shape, in a single write and in each slot of a multiple one" do
      expect(c("def a; @a = []; @h = {}; @t = [1]; end\ndef b; @m, @n = {}, []; end"))
        .to eq(:@a => "Array[Dynamic[top]]", :@h => "Hash[Dynamic[top], Dynamic[top]]", :@t => "[1]",
               :@m => "Hash[Dynamic[top], Dynamic[top]]", :@n => "Array[Dynamic[top]]")
    end

    it "asks the declared-parameter census with the def, the class and the body's scope, for an instance def only" do
      allow(indexer::DeclaredParamWrites).to receive(:collect).and_call_original
      c("def a(v); @a = v; end\ndef self.s(v); @s = v; end")

      expect(indexer::DeclaredParamWrites)
        .to have_received(:collect).once
        .with(have_attributes(name: :a), "C", have_attributes(self_type: combinator.nominal_of("C")))
    end
  end

  # Every arm of the walk hands on the four side tables a def body's census fills or reads: the mutations, the
  # read-before-write evidence, the initializer writes and the definite-assignment summary. One body shows all
  # four: a transient `nil` a same-class call overwrites, a tuple another method mutates, and an ivar a method
  # reads before a sibling writes it.
  describe "what each arm hands on" do
    let(:body) do
      "def initialize; @i = nil; mask!; @t = [1]; end\ndef mask!; @i = 1; end\ndef use; @r.x; @t << 2; end\n" \
        "def set; @r = 2; end"
    end
    let(:inline) { body.tr("\n", ";") }
    let(:census) { { :@t => "Array[Dynamic[top]]", :@i => "1", :@r => "2?" } }

    it "is the whole census below a header, nested or rooted below `class <<`" do
      expect(seeds("module M\nclass C\n#{body}\nend\nend\n")).to eq("M::C" => census)
      expect(seeds("class O\nclass << self\nclass ::C\n#{body}\nend\nend\nend\n")).to eq("C" => census)
    end

    it "is the whole census in the block of a class-creating write, and in a header or a write inside it" do
      expect(seeds("K = Class.new do\n#{body}\nend\n")).to eq("K" => census)
      expect(seeds("K = Class.new do\nclass D\n#{body}\nend\nend\n")).to eq("D" => census)
      expect(seeds("K = Class.new do\nL = Class.new do\n#{body}\nend\nend\n")).to eq("L" => census)
    end

    it "is the whole census in the receiver and the arguments of a class-creating call, written or not" do
      expect(seeds("class C\nK = Class.new((#{inline}; Object)) { }\nend\n")).to eq("C" => census)
      expect(seeds("class C\nK = (#{inline}; Class).new { }\nend\n")).to eq("C" => census)
      expect(seeds("class C\nClass.new((#{inline}; Object)) { }\nend\n")).to eq("C" => census)
      expect(seeds("class C\n(#{inline}; Class).new { }\nend\n")).to eq("C" => census)
    end

    it "is the whole census in an eval-family block, in its arguments, and in a header or a write inside it" do
      expect(seeds("class X; end\nX.class_eval do\n#{body}\nend\n")).to eq("X" => census)
      expect(seeds("class C\nX.class_eval((#{inline}; 1)) { }\nend\n")).to eq("C" => census)
      expect(seeds("class C\n(#{inline}; X).class_eval { }\nend\n")).to eq("C" => census)
      expect(seeds("X.class_eval do\nclass D\n#{body}\nend\nend\n")).to eq("D" => census)
      expect(seeds("X.class_eval do\nself::L = Class.new do\n#{body}\nend\nend\n")).to eq("X::L" => census)
    end

    # The table of instance defs holds no def of an `instance_eval` block, so no call there is credited. Its
    # `def initialize` is `X.initialize`, which `new` never calls, so its writes exempt nothing (#3419).
    it "is the census less the same-class call's credit and the initializer in an `instance_eval` block" do
      expect(seeds("class X; end\nX.instance_eval do\n#{body}\nend\n"))
        .to eq("X" => census.merge(:@i => "1?", :@t => "Array[Dynamic[top]]?"))
    end

    it "is the whole census in the expression of a `class <<`, under the class a write gave the block around it" do
      expect(seeds("class C\nclass << (#{inline}; self)\nend\nend\n")).to eq("C" => census)
      expect(seeds("K = Class.new do\nclass << (#{inline}; self)\nend\nend\n")).to eq("K" => census)
    end

    it "is the whole census for defs in a block, and nothing in a `class <<` body or a block no write names" do
      expect(seeds("class C\n[1].each do\n#{body}\nend\nend\n")).to eq("C" => census)
      expect(seeds("class C\nclass << self\n#{body}\nend\nClass.new do\n#{body}\nend\nend\n")).to eq({})
    end
  end

  describe "a write under a guard" do
    # `@x = v unless @x` records `v` alone; the predicate then folds to it and reports a working program. The guard
    # adds the `nil` the body runs under. Each ivar below has a write in `initialize`, so no read-before-write `nil`
    # is in the way.
    def guarded(*statements)
      ivars = statements.join.scan(/@\w+(?= = )/).uniq
      c("def initialize; #{ivars.map { |ivar| "#{ivar} = 0" }.join('; ')}; end\ndef m\n#{statements.join("\n")}\nend")
    end

    it "adds `nil` to a write in the body of `unless @x`, `unless defined?(@x)` and their `&&` and `||`" do
      expect(guarded('@x = "d" unless @x', "@y = 1 unless defined?(@y)", "@z = 1 unless @z && other",
                     "@w = 2 unless other || @w", "@c = 3 unless defined?(@c) && other",
                     "@d = 4 unless other || defined?(@d)"))
        .to eq(:@x => '"d" | 0 | nil', :@y => "0 | 1 | nil", :@z => "0 | 1 | nil", :@w => "0 | 2 | nil",
               :@c => "0 | 3 | nil", :@d => "0 | 4 | nil")
    end

    it "adds it in the body of `if @x.nil?`, `if !@x` and their `&&` and `||`" do
      expect(guarded("@v = 1 if @v.nil?", "@u = 2 if !@u", "@a = 3 if @a.nil? || other", "@b = 4 if other && !@b"))
        .to eq(:@v => "0 | 1 | nil", :@u => "0 | 2 | nil", :@a => "0 | 3 | nil", :@b => "0 | 4 | nil")
    end

    it "adds none for a test that does not say the ivar is missing, or that tests another one" do
      expect(guarded("@t = 6 if @t", "@s = 7 if @s.empty?", "@r = 8 unless @r.nil?", "@q = 9 unless defined?(x)",
                     "@e = 5 if x.nil? && y.!", "@p = 4 unless @o"))
        .to eq(:@t => "0 | 6", :@s => "0 | 7", :@r => "0 | 8", :@q => "0 | 9", :@e => "0 | 5", :@p => "0 | 4")
    end

    # A falsey default under the guard carries no precision the predicate has not given: it is skipped, where the
    # same write under no guard is recorded.
    it "skips a `nil` or `false` write under its guard, and records one under another condition" do
      expect(guarded("@n = nil unless @n", "@f = false unless @f", "@k = nil if cond", "@g = false unless @n"))
        .to eq(:@n => "0", :@f => "0", :@k => "0?", :@g => "0 | false")
    end

    it "guards the body alone: the other branch and the predicate are walked without it" do
      body = "if @x.nil?\n@x = 1\nelse\n@y = 2\nend\nunless @p\n@p = 1\nelse\n@q = 2\nend\n" \
             "if (@r = compute)\n@s = 1\nelsif @t.nil?\n@t = 3\nend"

      expect(guarded(body)).to eq(:@x => "0 | 1 | nil", :@y => "0 | 2", :@p => "0 | 1 | nil", :@q => "0 | 2",
                                  :@r => "0 | Dynamic[top]", :@s => "0 | 1", :@t => "0 | 3 | nil")
    end

    it "keeps the guard through what the body nests, and adds the guards of a conditional inside it" do
      body = "unless @x\n[1].each { @x = \"s\" }\nif cond\n@x = :t\nend\nif @y.nil?\n@y = 2\n@x = 4\nend\n" \
             "@z = 3 unless @x\nend"

      expect(guarded(body)).to eq(:@x => '"s" | 0 | 4 | :t | nil', :@y => "0 | 2 | nil", :@z => "0 | 3")
    end

    it "walks a conditional with no body, and one that is an expression" do
      expect(guarded("if @x.nil?\nend", "@a = (cond ? 1 : 2)", "@b = 1 if (@c = 2)")).to eq(
        :@a => "0 | 1 | 2", :@b => "0 | 1", :@c => "0 | 2"
      )
    end

    it "reads a guard's name off an ivar only: not off a `defined?` of anything else or a test of another receiver" do
      expect(c("def m\n@x = 1 unless defined?(yield)\n@y = 2 if !(a && b)\nend")).to eq(:@x => "1", :@y => "2")
    end
  end

  describe "a compound write" do
    # #1175 — `@x ||= v` is the memo idiom: the rvalue, and the `nil` the ivar holds until the first call.
    it "records `||=` as the rvalue or `nil`, an empty literal without its shape" do
      expect(c("def initialize; @n = 0; end\ndef a; @m ||= []; @n ||= \"s\"; end"))
        .to eq(:@n => '"s" | 0 | nil', :@m => "Array[Dynamic[top]]?")
    end

    it "skips a `||=` whose rvalue has no truthy part: a falsey literal, or a guard that raises" do
      expect(c('def b; @f ||= false; @g ||= nil; @h ||= raise("x"); @i ||= (c ? nil : 1); end')).to eq(:@i => "1?")
    end

    # `@x &&= v` writes only when `@x` already holds a truthy value, so it counts only beside a write that can give
    # the ivar one, wherever that write is in the source.
    it "joins `&&=` with the ivar's other writes, before or after it in the source" do
      expect(c("def initialize; @t = \"i\"; end\ndef a; @t &&= \"r\"; end")).to eq(:@t => '"i" | "r"')
      expect(c("def a; @t &&= \"r\"; end\ndef b; @t = \"i\"; end")).to eq(:@t => '"i" | "r"')
    end

    it "leaves an ivar only `&&=` writes unseeded, and a class with nothing else untouched" do
      expect(seeds("class C\ndef a; @only &&= 1; end\ndef b; @other = 2; end\nend\n" \
                   "class D; def a; @d &&= 1; end; end\n"))
        .to eq("C" => { :@other => "2" })
    end

    it "records each other compound form through the same arm, in a block and under a guard" do
      body = "def initialize; @a = 0; @b = \"s\"; end\ndef m\n[1].each { @a += 1 }\n@b &&= :t if cond\n" \
             "@c ||= 1 unless @c\nend"

      expect(c(body)).to eq(:@a => "0 | Integer", :@b => '"s" | :t', :@c => "1?")
    end
  end

  # `@x op= v` stores `@x op v`, so its contribution is the operator dispatched on what the class's other writes
  # store, once the walk has them all: the methods run in any order.
  describe "an `op=` write" do
    it "dispatches the operator on the seed the other writes give, whatever the source order" do
      expect(c("def initialize; @n = 0; @s = \"a\"; @f = 0.5; end\ndef a; @n += 1; @s += \"b\"; @f += 1; end"))
        .to eq(:@n => "0 | Integer", :@s => '"a" | non-empty-string', :@f => "0.5 | Float")
      expect(c("def a; @n += 1; end\ndef initialize; @n = 0; end")).to eq(:@n => "0 | Integer")
    end

    it "seeds an ivar only `op=` writes from the widened rvalues, and dispatches on that" do
      expect(c("def a; @only += 1; @only -= 0.5; end\ndef b; @str += \"x\"; end"))
        .to eq(:@only => "Float | Integer", :@str => "String | non-empty-string")
    end

    it "sees what a `&&=` or a `||=` of the same ivar stores, and seeds an `&&=` beside an `op=`-only ivar" do
      expect(c("def initialize; @x = 1; end\ndef shrink; @x &&= 1.5; end\ndef grow; @x += 1; end"))
        .to eq(:@x => "1 | 1.5 | Float | Integer")
      expect(c("def c; @s ||= \"a\"; @s += \"b\"; end")).to eq(:@s => '"a" | nil | non-empty-string')
      expect(c("def b; @o += 1; end\ndef c; @o &&= :s; end")).to eq(:@o => ":s | Integer")
    end

    # A member the dispatch declines whose class the environment knows lacks the operator: the write raises there
    # and stores nothing. Any other declining member stores what the pre-pass cannot see, and keeps the rvalue.
    it "dispatches the members it can type together, and joins the rvalue only for a member it cannot know" do
      expect(c("def reset; @x = nil; end\ndef a; @x = 0.5; end\ndef b; @x += 1; end")).to eq(:@x => "0.5 | Float | nil")
      expect(c("def a; @x = :none; end\ndef b; @x = 1; end\ndef c; @x += 1; end")).to eq(:@x => "1 | :none | Integer")
      expect(c("def a(v); @x = v; end\ndef b; @x += 1; end")).to eq(:@x => "Dynamic[top] | Integer")
      expect(c("def a; @x = Foo.new; end\ndef b; @x = 1; end\ndef c; @x += 1; end"))
        .to eq(:@x => "1 | Dynamic[top] | Integer")
      expect(c("def a; @x = Object.new; end\ndef b; @x = 1; end\ndef c; @x += 1; end"))
        .to eq(:@x => "1 | Integer | Object")
    end

    it "falls back to the rvalue when no member of the seed takes the operator" do
      expect(c("def a; @x = nil; end\ndef b; @x += 1; end")).to eq(:@x => "Integer?")
      expect(c("def a; @x = :s; end\ndef b; @x = nil; end\ndef c; @x += 1.5; end")).to eq(:@x => ":s | Float | nil")
    end

    # Each pass dispatches every held write on what the pass before stored, and stops once a pass adds nothing or
    # the receiver is wider than the cap.
    it "repeats the dispatch once per held write, so a chain of them is in the seed" do
      expect(c("def initialize; @a = [0]; end\ndef a; @a += [:s1]; end\ndef b; @a += [:s2]; end"))
        .to eq(:@a => "Array[0 | :s1 | Dynamic[top]] | Array[0 | :s2 | Dynamic[top]] | Array[0 | Dynamic[top]] | " \
                      "[0, :s1] | [0, :s2] | [0]")
    end

    it "floors a chain whose receiver passes forty members to `Dynamic[top]`" do
      writes = ->(count) { (1..count).map { |i| "def m#{i}; @a += [:s#{i}]; end" }.join("\n") }

      expect(c("def initialize; @a = [0]; end\n#{writes.call(20)}")).to eq(:@a => "Dynamic[top]")
      expect(c("def initialize; @a = [0]; end\n#{writes.call(19)}").fetch(:@a)).to include("[0, :s19]")
    end

    it "stops at a pass that adds nothing before it asks how wide the receiver is" do
      shapes = (1..45).map { |i| "def s#{i}; @x = { k#{i}: 1 }; end" }.join("\n")
      entry = c("#{shapes}\ndef z; @x = Time.now.to_i; end\ndef o1; @x += 1; end\ndef o2; @x += 2; end").fetch(:@x)

      expect(entry.split(" | ").size).to eq(46)
    end

    it "counts a receiver of one class as one member" do
      expect(c("def a; @x = 0; end\ndef b; @x += 1; end\ndef d; @x += 2; end")).to eq(:@x => "0 | Integer")
    end

    # The rvalue's class differs from the result's here, so the join shows: `"a" * 3` is a String, and `3` an Integer.
    it "joins the rvalue for a declining member of a class the environment does not know, and for no known one" do
      body = "def a; @x = \"a\"; end\ndef a2; @x = %s.new; end\ndef b; @x *= 3; end"

      expect(c(format(body, "Object"))).to eq(:@x => '"a" | Object | String')
      expect(c(format(body, "Bar"), bars)).to eq(:@x => '"a" | Bar | Integer | String')
    end
  end

  describe "a write through a target" do
    # N1 — each ivar target takes its slot of the right-hand side, as a local does (#1110); a right-hand side the
    # binder cannot decompose is unknown, not `nil`.
    it "records each ivar of a multiple assignment with its slot's type" do
      body = "def a; @a, @b = 1, \"s\"; end\ndef b; @c, @d = compute; end\ndef c; (@e, @f), *@g = [1, 2], 3, 4; end\n" \
             "def d; @h, x = :h, []; end\ndef e; @i, @j = [1, nil]; end\ndef f; x, y = 1, 2; end\ndef g; @k, @l = 7 end"

      expect(c(body)).to eq(:@a => "1", :@b => '"s"', :@c => "Dynamic[top]", :@d => "Dynamic[top]", :@e => "1",
                            :@f => "2", :@g => "[3, 4]", :@h => ":h", :@i => "1", :@j => "nil", :@k => "7",
                            :@l => "nil")
    end

    # Issue #1217 — a rescue reference contributes the exception the clause names, a `for` index the unknown floor.
    it "records a rescue reference as the clause's exception and a `for` index as unknown" do
      body = "def a\nwork\nrescue ArgumentError => @err\n1\nend\ndef b; for @x in xs; end; end\n" \
             "def c; for @y, z in xs; end; end\ndef d; for *@w in xs; end; end\ndef e\nwork\nrescue => @any\n1\nend\n" \
             "def f; for (@p, @q), r in xs; end; end\ndef g\nwork\nrescue TypeError, KeyError => @two\n1\nend"

      expect(c(body)).to eq(:@err => "ArgumentError", :@x => "Dynamic[top]", :@y => "Dynamic[top]",
                            :@w => "Dynamic[top]", :@any => "StandardError", :@p => "Dynamic[top]",
                            :@q => "Dynamic[top]", :@two => "KeyError | TypeError")
    end

    it "records nothing for a rescue or a `for` that binds no ivar" do
      expect(c("def g\nwork\nrescue => e\n1\nend\ndef h; for i in xs; end; end\ndef i; for *rest in xs; end; end"))
        .to eq({})
    end

    # #1110 — the seed drops the binder's optimistic marks, so it keeps the `nil` a slot holds in one member of the
    # right-hand side; the scope answers whether a class outside the core list converts to an array.
    it "keeps the `nil` one member of the right-hand side holds in a slot, and wraps a value with no `to_ary`" do
      expect(c("def m; @a, @b = (c ? [1, 2] : [nil, 3]); end")).to eq(:@a => "1?", :@b => "2 | 3")
      expect(c("def n; @c, @d = Time.now; end")).to eq(:@c => "Time", :@d => "nil")
    end
  end

  # #1931 — `instance_variable_set` on `self` writes an ivar no write node shows.
  describe "a reflective write" do
    it "records a literal name with the value's type, on the implicit or `self` receiver alone" do
      body = "def a; instance_variable_set(:@k, 1); end\ndef b; self.instance_variable_set(\"@s\", :x); end\n" \
             "def c; other.instance_variable_set(:@o, 1); end"

      expect(c(body)).to eq(:@k => "1", :@s => ":x")
    end

    # A name the analysis cannot read may write any ivar of the class.
    it "turns every entry of a class gradual when a name is computed, and leaves the other classes" do
      source = "class C\ndef initialize; @t = 5; @u = \"s\"; end\n" \
               "def a(k, v); instance_variable_set(:\"@\#{k}\", v); end\nend\n" \
               "class D\ndef initialize; @t = 5; end\nend\n" \
               "class E; def a(k, v); instance_variable_set(k, v); end; end\n"

      expect(seeds(source)).to eq("C" => { :@t => "Dynamic[top]", :@u => "Dynamic[top]" }, "D" => { :@t => "5" })
    end
  end

  # #2490, #2941 — a block or a `class <<` body whose `self` is another object writes that object's ivars; a `def` in
  # it that runs on an instance again counts.
  describe "code whose `self` is another object" do
    it "leaves out what a foreign block or `class << obj` body writes, and counts a def or `define_method` in it" do
      body = "def m(obj)\nclass << obj\n@direct = 1\ndef re; @w = 4; end\nend\n" \
             "Other.new.instance_eval { @x = 1 }\nself.instance_eval { @y = 2 }\n" \
             "singleton_class.class_eval { define_method(:dm) { @v = 6 } }\nend"

      expect(c(body)).to eq(:@w => "4", :@y => "2", :@v => "6")
    end

    it "counts none of it in a singleton-side def" do
      expect(c("def self.s(obj)\nclass << obj\ndef re; @sv = 5; end\nend\n@own = 1\nend")).to eq(:@own => "1")
    end
  end

  # B2.3 — an ivar some method reads before it writes it, and no initializer writes, is `nil` at that read.
  describe "the read-before-write `nil`" do
    it "adds `nil` to an ivar a method reads first, and none to one a method writes first" do
      expect(c("def use; @x.foo; end\ndef set; @x = 1; end\ndef m; @y = 2; @y.foo; end")).to eq(:@x => "1?", :@y => "2")
    end

    it "adds none for an ivar `initialize` writes, in any write form, and none to an ivar no write seeds" do
      body = "def initialize; @x = 1; @m, (@n, *@o) = 1, [2, 3]; @c ||= 4; instance_variable_set(:@r, 5); end\n" \
             "def use; @x.a; @m.b; @n.c; @o.d; @c.e; @r.f; @none.g; end\ndef set; @x = 6; @m = 7; end"

      expect(c(body)).to eq(:@x => "1 | 6", :@m => "1 | 7", :@n => "2", :@o => "[3]", :@c => "4?", :@r => "5")
    end

    it "reads the right-hand side before the target: `@x = @x + 1` and a multiple assignment's value read first" do
      expect(c("def m; @x = @x + 1; end\ndef n; @a, @b = @b, 1; end\ndef o; instance_variable_set(:@k, @k); end"))
        .to eq(:@x => "Dynamic[top]?", :@a => "Dynamic[top]", :@b => "1?", :@k => "Dynamic[top]?")
    end

    it "takes every ivar target of a multiple assignment in `initialize` as written: front, splat, back and nested" do
      body = "def initialize; @a, *@b, @c = 1, 2, 3; x, *y = 1; @d, (@e, *@f, @g) = 1, [2, 3, 4]; end\n" \
             "def use; @a.x; @b.x; @c.x; @d.x; @e.x; @f.x; @g.x; end"

      expect(c(body)).to eq(:@a => "1", :@b => "[2]", :@c => "3", :@d => "1", :@e => "2", :@f => "[3]", :@g => "4")
    end

    # A read in the receiver of a call target counts, front or back; in a splatted one it is not looked for.
    it "counts a read in a call target's receiver, front or back" do
      expect(c("def m; @o.x, a, @p.y = 1, 2, 3; end\ndef n; a, *@q.z = 1, 2; end\ndef s; @o = 1; @p = 2; @q = 3; end"))
        .to eq(:@o => "1?", :@p => "2?", :@q => "3")
    end

    it "counts a read in a target's receiver, and takes an ivar a splat or a nested target binds as written" do
      body = "def m; @obj.x, @y = 1, 2; (@p, @q), *@r = 1; @y.a; @p.b; @q.c; @r.d; end\ndef set; @obj = 1; end"

      expect(c(body)).to eq(:@y => "2", :@p => "1", :@q => "nil", :@r => "[]", :@obj => "1?")
    end

    it "stops at a def or a class nested in the body, and walks its blocks" do
      body = "def m\ndef inner; @x.foo; end\nclass K; @x.bar; end\n[1].each { @y.baz }\nend\n" \
             "def set; @x = 1; @y = 2; end"

      expect(c(body)).to eq(:@x => "1", :@y => "2?")
    end

    # #2490 — what a block whose `self` is another object reads is that object's; a def it holds is skipped too.
    it "leaves out a read in a block whose `self` is another object, and in a def below `class << obj`" do
      body = "def m(obj)\nOther.new.instance_eval { @x.foo }\nclass << obj\ndef re; @late.x; end\nend\n@y.foo\nend\n" \
             "def set; @x = 1; @y = 2; @late = 3; end"

      expect(c(body)).to eq(:@x => "1", :@y => "2?", :@late => "3")
    end

    # A class-body `@x = nil` writes the class object's ivar, and says that the author knows `@x` may be nil.
    it "adds none for an ivar the class body writes, in any write form" do
      body = "@x = nil\n@y ||= 1\n@z &&= 1\n@w += 1\n[1].each { @v = 1 }\n" \
             "def use; @x.a; @y.b; @z.c; @w.d; @v.e; end\ndef set; @x = 1; @y = 2; @z = 3; @w = 4; @v = 5; end"

      expect(c(body)).to eq(:@x => "1", :@y => "2", :@z => "3", :@w => "4", :@v => "5")
    end

    it "takes a class-body write no further than its class: not a def's, a nested class's or a reopening's" do
      source = "class C\ndef self.boot; @x = :boot; end\nclass Inner; @y = nil; end\n" \
               "def use; @x.a; @y.b; @z.c; end\ndef set; @x = 1; @y = 2; @z = 3; end\nend\nclass D; @z = nil; end\n"

      expect(seeds(source)).to eq("C" => { :@x => "1 | :boot | nil", :@y => "2?", :@z => "3?" })
    end

    # #1768 — a `define_method` block is a method body: its write does not exempt the ivar, and takes back the
    # exemption a class-body write of the same ivar gave. Its arguments are class-body code.
    it "keeps the `nil` for an ivar a `define_method` block writes, and exempts one its arguments write" do
      body = "@x = nil\ndefine_method(:m) { @x = \"s\" }\ndefine_method((@y = nil; :n)) { 1 }\n" \
             "def use; @x.a; @y.b; end\ndef set; @y = 2; end"

      expect(c(body)).to eq(:@x => '"s"?', :@y => "2")
    end

    it "writes no class-body census below an unnameable cref" do
      source = "class C\nclass << self\nclass D\n@x = nil\ndef use; @x.a; end\ndef set; @x = 1; end\n" \
               "end\nclass ::E\n@x = nil\ndef use; @x.a; end\ndef set; @x = 1; end\nend\nend\nend\n"

      expect(seeds(source)).to eq("E" => { :@x => "1" })
    end

    it "is per class: an initializer or a read of another class changes nothing" do
      source = "class C\ndef use; @x.a; end\ndef set; @x = 1; end\nend\n" \
               "class D\ndef initialize; @x = 2; end\ndef set; @y = 3; end\nend\nclass E; def use; @y.a; end; end\n"

      expect(seeds(source)).to eq("C" => { :@x => "1?" }, "D" => { :@x => "2", :@y => "3" })
    end

    it "collects the evidence in a singleton-side def as in an instance one" do
      expect(c("def self.use; @x.a; end\ndef self.set; @x = 1; end")).to eq(:@x => "1?")
    end

    it "leaves out a read in a foreign block wherever a multiple assignment holds it: its value, a target, a nest" do
      body = "def a; x, y = Other.new.instance_eval { @r.x }, 1; end\n" \
             "def b; Other.new.instance_eval { @s }.x, y = 1, 2; end\n" \
             "def c; (Other.new.instance_eval { @t }.x, z), y = [1, 2], 3; end\ndef set; @r = 1; @s = 2; @t = 3; end"

      expect(c(body)).to eq(:@r => "1", :@s => "2", :@t => "3")
    end

    it "counts a read in the receiver of a nested target, and reads no name off a bare splat" do
      expect(c("def m; (@obj.x, z), y = [1, 2], 3; end\ndef set; @obj = 1; end")).to eq(:@obj => "1?")
      expect(c("def m; a, * = [1, 2]; @x = a; end")).to eq(:@x => "Dynamic[top]")
    end

    # #2941 — a `define_method` block that a `class_eval` on the object's own class holds runs on an instance again.
    it "counts a read in a `define_method` block reentered below a block whose `self` is another object" do
      body = "def m; singleton_class.class_eval { define_method(:dm) { @v.x } }; end\ndef set; @v = 1; end"

      expect(c(body)).to eq(:@v => "1?")
    end

    # #3419 — nothing runs on the instance before `initialize`, so its read of an ivar it never writes is `nil`.
    it "takes evidence from an initializer's read of an ivar it never writes" do
      expect(c("def initialize; @y.foo; end\ndef set; @y = 1; end")).to eq(:@y => "1?")
      expect(c("def initialize(c); raise unless @y; end\ndef set; @y = 1; end")).to eq(:@y => "1?")
    end

    # What the ivar holds once `initialize` has written it is not `nil`, whatever an earlier read of it saw.
    it "takes none from an initializer's read of an ivar it writes later" do
      expect(c("def initialize; @y.foo; @y = 2; end\ndef set; @y = 1; end")).to eq(:@y => "1 | 2")
    end

    # A `super`, a `yield` or a call on the object may set the ivar before the read.
    it "takes none from an initializer's read after a statement that may run other code of the object" do
      body = "def initialize; super; @a.x; end\ndef initialize; yield; @b.x; end\ndef initialize; setup; @c.x; end\n" \
             "def initialize; self.prepare; @d.x; end\ndef initialize; foo(1); @e.x; end\n" \
             "def set; @a = 1; @b = 1; @c = 1; @d = 1; @e = 1; end"

      expect(c(body)).to eq(:@a => "1", :@b => "1", :@c => "1", :@d => "1", :@e => "1")
    end

    it "takes the initializer's reads before that statement, and those in a lambda or a call on another object" do
      body = "def initialize; @a.x; setup; end\ndef initialize; f = -> { setup }; @b.x; end\n" \
             "def initialize(obj); obj.setup; @c.x; end\ndef set; @a = 1; @b = 1; @c = 1; end"

      expect(c(body)).to eq(:@a => "1?", :@b => "1?", :@c => "1?")
    end

    # #3419 — `new` calls the instance `initialize` alone: a singleton-side one is a method like any other.
    it "takes a singleton-side `initialize` as no initializer" do
      expect(c("def self.initialize; @a = 1; end\ndef a; @a; end\ndef n; @a = 2; end")).to eq(:@a => "1 | 2 | nil")
      expect(c("class << self\ndef initialize; @b = 1; end\nend\ndef b; @b; end\ndef n; @b = 2; end"))
        .to eq(:@b => "2?")
    end

    it "takes each compound form for a write the reads after it follow, a `||=` that stores nothing included" do
      body = "def m; @f ||= false; @f.x; @b &&= 2; @b.x; @c += 1; @c.x; end\ndef set; @f = 1; @b = 1; @c = 1; end"

      expect(c(body)).to eq(:@f => "1", :@b => "1 | 2", :@c => "1 | Integer")
    end

    it "does not count a `define_method` block below `class <<` as class-body code" do
      body = "class << self\ndefine_method(:m) { @x = 0 }\nend\ndef r; @x; end\ndef w; @x = 1; end"

      expect(c(body)).to eq(:@x => "1?")
    end
  end

  # ADR-38 — a plugin declares further initializers: a `def` by name, or a block-taking call.
  describe "a plugin's additional initializers" do
    let(:setup) { "class FooTest\ndef setup; @conn = 1; end\ndef test_it; @conn; end\nend\n" }

    def initializer(**) = Rigor::Plugin::AdditionalInitializer.new(**)

    it "adds none for an ivar a declared def-form initializer of the class writes" do
      declared = plugin_scope(additional_initializers: [initializer(receiver_constraint: "FooTest", methods: [:setup])])

      expect(seeds(setup)).to eq("FooTest" => { :@conn => "1?" })
      expect(seeds(setup, declared)).to eq("FooTest" => { :@conn => "1" })
    end

    # #3419 — unlike `initialize`, a declared initializer may run after code that sets the ivar it reads.
    it "takes no evidence from a declared initializer's own reads" do
      declared = plugin_scope(additional_initializers: [initializer(receiver_constraint: "FooTest", methods: [:setup])])
      source = "class FooTest\ndef setup; @db.x; end\ndef connect; @db = 1; end\nend\n"

      expect(seeds(source, declared)).to eq("FooTest" => { :@db => "1" })
      expect(seeds(source)).to eq("FooTest" => { :@db => "1?" })
    end

    it "keeps it when the entry names another method or another class" do
      other_method = initializer(receiver_constraint: "FooTest", methods: [:other])
      other_class = initializer(receiver_constraint: "String", methods: [:setup])

      expect(seeds(setup, plugin_scope(additional_initializers: [other_method]))).to eq("FooTest" => { :@conn => "1?" })
      expect(seeds(setup, plugin_scope(additional_initializers: [other_class]))).to eq("FooTest" => { :@conn => "1?" })
    end

    it "matches a class below the entry's constraint, as the environment orders them" do
      source = setup.sub("FooTest", "Integer")
      numeric = plugin_scope(additional_initializers: [initializer(receiver_constraint: "Numeric", methods: [:setup])])
      string = plugin_scope(additional_initializers: [initializer(receiver_constraint: "String", methods: [:setup])])

      expect(seeds(source, numeric)).to eq("Integer" => { :@conn => "1" })
      expect(seeds(source, string)).to eq("Integer" => { :@conn => "1?" })
    end

    it "asks nothing of a scope with no environment, no registry or an empty one" do
      bare = Struct.new(:environment).new(nil)

      expect(described_class.send(:additional_initializer?, "C", :setup, nil)).to be(false)
      expect(described_class.send(:additional_initializer?, nil, :setup, plugin_scope)).to be(false)
      expect(described_class.send(:additional_initializer?, "C", :setup, bare)).to be(false)
      expect(described_class.send(:additional_initializer?, "C", :setup, empty)).to be(false)
      expect(described_class.send(:block_initializer?, "C", :before, nil)).to be(false)
      expect(described_class.send(:block_initializer?, nil, :before, plugin_scope)).to be(false)
      expect(described_class.send(:block_initializer?, "C", :before, bare)).to be(false)
      expect(described_class.send(:block_initializer?, "C", :before, empty)).to be(false)
    end

    # The two gates read the registry off the scope's environment and ask it to order the class under the entry's
    # constraint. Each only ever takes a `nil` away, so a lookup that fails or cannot be made is no match.
    describe "the lookup" do
      let(:entry) { initializer(receiver_constraint: "Numeric", methods: [:setup], block_methods: [:before]) }

      # A scope whose environment answers `ordering` for any pair of classes, with `registry` as its registry.
      def scope_ordering(ordering, registry = Struct.new(:additional_initializers).new([entry]))
        environment = Struct.new(:plugin_registry, :ordering) do
          def class_ordering(*) = ordering.is_a?(Class) ? raise(ordering) : ordering
        end
        Struct.new(:environment).new(environment.new(registry, ordering))
      end

      def gates(class_name, scope)
        [described_class.send(:additional_initializer?, class_name, :setup, scope),
         described_class.send(:block_initializer?, class_name, :before, scope)]
      end

      it "matches the constraint's own class without asking, and a class the environment orders equal or below" do
        expect(gates("Numeric", scope_ordering(:unknown))).to eq([true, true])
        expect(gates("Integer", scope_ordering(:subclass))).to eq([true, true])
        expect(gates("Integer", scope_ordering(:equal))).to eq([true, true])
        expect(gates("Integer", scope_ordering(:superclass))).to eq([false, false])
        expect(gates("Integer", scope_ordering(:unknown))).to eq([false, false])
      end

      it "matches an entry by the name it covers on its own side alone" do
        scope = scope_ordering(:subclass)

        expect(described_class.send(:additional_initializer?, "Integer", :before, scope)).to be(false)
        expect(described_class.send(:block_initializer?, "Integer", :setup, scope)).to be(false)
      end

      it "takes an ordering or a registry that raises as no match" do
        raising = Struct.new(:listed) { def additional_initializers = raise(StandardError) }.new([entry])

        expect(gates("Integer", scope_ordering(StandardError))).to eq([false, false])
        expect(gates("Integer", scope_ordering(:subclass, raising))).to eq([false, false])
        expect(described_class.send(:class_matches_constraint?, "Integer", "Numeric", nil)).to be(false)
      end

      it "asks nothing of a registry that is empty or lists no initializers" do
        expect(gates("Integer", scope_ordering(:subclass, []))).to eq([false, false])
        expect(gates("Integer", scope_ordering(:subclass, Struct.new(:other).new(1)))).to eq([false, false])
      end
    end

    describe "in block form" do
      let(:source) { "class FooSpec\nbefore { @user = 1 }\nit { @user.x }\nother { @o = 2 }\ndef use; @user; end\nend" }
      let(:declared) do
        plugin_scope(additional_initializers: [initializer(receiver_constraint: "FooSpec", block_methods: [:before])])
      end

      it "walks the block of a declared call as an instance body whose writes are initializer writes" do
        expect(seeds(source)).to eq({})
        expect(seeds(source, declared)).to eq("FooSpec" => { :@user => "1" })
      end

      it "walks none for a def-form entry, a call with no literal block, another class or no class" do
        entry = initializer(receiver_constraint: "FooSpec", methods: [:before])
        def_form = plugin_scope(additional_initializers: [entry])
        shapes = "class FooSpec\nbefore(&blk)\nbefore\nbefore { }\nclass << self; before { @s = 1 }; end\nend\n" \
                 "before { @top = 1 }\nclass Other; before { @o = 1 }; end\n"

        expect(seeds(source, def_form)).to eq({})
        expect(seeds(shapes, declared)).to eq({})
      end

      it "gathers the block as a def body: its mutations, its nested blocks, and the defs the walk reaches in it" do
        body = "class FooSpec\nbefore { @a = [1]; @a << 2; @b = @c; nested { @d = 1 }; def x; @e = 1; end }\n" \
               "def use; @a; @b; @c; @d; @e; end\nend\n"

        expect(seeds(body, declared))
          .to eq("FooSpec" => { :@a => "Array[Dynamic[top]]", :@b => "Dynamic[top]", :@d => "1", :@e => "1?" })
      end

      # A write the class-body census does not see as one (a target of a multiple assignment, a reflective write) is
      # an initializer write all the same.
      it "counts a target of a multiple assignment and a reflective write in the block as initializer writes" do
        body = "class FooSpec\nbefore { @user, @o = 1, 2; instance_variable_set(:@v, 3); @s = self }\n" \
               "def use; @user; @o; @v; end\nend\n"

        expect(seeds(body, declared))
          .to eq("FooSpec" => { :@user => "1", :@o => "2", :@v => "3", :@s => "FooSpec" })
      end

      it "counts none of what a block whose `self` is another object writes in it" do
        body = "class FooSpec\nbefore { Other.new.instance_eval { @z, @w = 1, 2 } }\ndef set; @z = 2; end\n" \
               "def use; @z; end\nend\n"

        expect(seeds(body, declared)).to eq("FooSpec" => { :@z => "2?" })
      end

      it "walks the block under the class an eval-family block names, with no header around it" do
        entry = initializer(receiver_constraint: "X", block_methods: [:before])

        expect(seeds("X.class_eval { before { @a = 1 } }\n", plugin_scope(additional_initializers: [entry])))
          .to eq("X" => { :@a => "1" })
      end
    end
  end

  # C2 — an opening `@x = nil` a later statement of the same body definitely overwrites is never the ivar's value at
  # the method's end, so it is no member of the class's union.
  describe "a transient `@x = nil`" do
    it "drops one a later statement of the body overwrites, whatever stands between" do
      expect(c("def initialize; @x = nil; @y = 2; foo; @x = 1; end")).to eq(:@y => "2", :@x => "1")
    end

    it "keeps one nothing overwrites, one a `nil` overwrites, and the only statement of a body" do
      expect(c("def a; @x = nil; end\ndef b; @y = nil; other; end\ndef c; @z = nil; @z = nil; end\n" \
               "def d; @w = nil; @v = 1; end"))
        .to eq(:@x => "nil", :@y => "nil", :@z => "nil", :@w => "nil", :@v => "1")
    end

    it "drops one a conditional overwrites in both branches, and keeps one a branch may leave" do
      body = "def a\n@x = nil\nif c\n@x = 1\nelse\n@x = 2\nend\nend\n" \
             "def b\n@y = nil\nif c\n@y = 1\nend\nend\ndef d\n@z = nil\n@z = 1 if c\nend\n" \
             "def e\n@w = nil\nunless c\n@w = 1\nelse\n@w = 2\nend\nend\n" \
             "def f\n@v = nil\nif c\n@v = 1\nelsif d\n@v = 2\nelse\n@v = 3\nend\nend\n" \
             "def g\n@u = nil\nif c\nelse\n@u = 1\nend\nend"

      expect(c(body)).to eq(:@x => "1 | 2", :@y => "1?", :@z => "1?", :@w => "1 | 2", :@v => "1 | 2 | 3 | nil",
                            :@u => "1?")
    end

    it "drops one a `case` with an `else` overwrites in every arm, and keeps one an arm or no `else` may leave" do
      body = "def a\n@x = nil\ncase v\nwhen 1 then @x = 1\nwhen 2 then @x = 2\nelse @x = 3\nend\nend\n" \
             "def b\n@y = nil\ncase v\nwhen 1 then @y = 1\nend\nend\n" \
             "def c\n@z = nil\ncase v\nwhen 1 then @z = 1\nelse other\nend\nend\n" \
             "def d\n@w = nil\ncase v\nwhen 1 then other\nelse @w = 1\nend\nend"

      expect(c(body)).to eq(:@x => "1 | 2 | 3", :@y => "1?", :@z => "1?", :@w => "1?")
    end

    # A `case … in` is another node than a `case … when`, and no statement the summary reads.
    it "keeps one a `case … in` overwrites in every arm" do
      body = "def c\n@z = nil\ncase v\nin Integer then @z = 1\nelse @z = 2\nend\nend"

      expect(c(body)).to eq(:@z => "1 | 2 | nil")
    end

    # A path a `raise` ends never observes the ivar at the method's end; a `return` does.
    it "takes a branch that ends in `raise` or `fail` as overwriting, and one that returns as not" do
      body = "def a\n@x = nil\nif c\n@x = 1\nelse\nraise \"no\"\nend\nend\n" \
             "def b\n@y = nil\nif c\n@y = 1\nelse\nother\nfail \"no\"\nend\nend\n" \
             "def d\n@z = nil\nif c\n@z = 1\nelse\nobj.raise \"no\"\nend\nend\n" \
             "def e\n@w = nil\nif c\nreturn\nelse\n@w = 1\nend\nend\n" \
             "def f\n@v = nil\nreturn\n@v = 1\nend\n" \
             "def g\n@u = nil\nif c\n@u = 1\nelse\nraise_it\nend\nend"

      expect(c(body)).to eq(:@x => "1", :@y => "1", :@z => "1?", :@w => "1?", :@v => "1?", :@u => "1?")
    end

    # #3419 — the path a `return` in a conditional with no `else` takes leaves the method with the `nil`.
    it "keeps one a conditional with no `else` may return before overwriting" do
      expect(c("def b; @y = nil; return if c; @y = 1; end\ndef e; @w = nil; return unless c; @w = 1; end"))
        .to eq(:@y => "1?", :@w => "1?")
    end

    it "keeps one an `elsif` arm or a `case` arm with no `else` may return before overwriting" do
      body = "def a\n@x = nil\nif c\n@x = 1\nelsif d\nreturn\nend\n@x = 2\nend\n" \
             "def b\n@y = nil\ncase v\nwhen 1 then return\nend\n@y = 1\nend"

      expect(c(body)).to eq(:@x => "1 | 2 | nil", :@y => "1?")
    end

    it "drops one an arm overwrites before it returns, and one an `elsif` arm without a `return` leaves" do
      body = "def a\n@x = nil\nif c\n@x = 1\nreturn\nend\n@x = 2\nend\n" \
             "def b\n@y = nil\nif c\n1\nelsif d\n2\nend\n@y = 1\nend"

      expect(c(body)).to eq(:@x => "1 | 2", :@y => "1")
    end

    # A statement that is no conditional may return through a `&&`, a loop, a block or a `begin`; a lambda's
    # `return` leaves the lambda alone.
    it "keeps one any other statement may return in before overwriting, and drops one past a lambda's `return`" do
      body = "def a; @a = nil; c and return; @a = 1; end\ndef b; @b = nil; while c; return; end; @b = 1; end\n" \
             "def d; @d = nil; [1].each { return }; @d = 1; end\ndef e; @e = nil; begin; return; end; @e = 1; end\n" \
             "def f; @f = nil; g = -> { return }; @f = 1; end"

      expect(c(body)).to eq(:@a => "1?", :@b => "1?", :@d => "1?", :@e => "1?", :@f => "1")
    end

    it "looks at the statements of the body alone: a write in a block, a loop or a `begin` does not overwrite" do
      body = "def a; @x = nil; [1].each { @x = 1 }; end\ndef b; @y = nil; while c; @y = 1; end; end\n" \
             "def d\n@z = nil\nbegin\n@z = 1\nend\nend\ndef e; @w = nil; @w ||= 1; end"

      expect(c(body)).to eq(:@x => "1?", :@y => "1?", :@z => "1?", :@w => "1?")
    end

    it "drops it in any def body the census walks: a singleton-side one, and one a block or a write names" do
      source = "class C\ndef self.boot; @x = nil; @x = 1; end\nend\nclass X; end\n" \
               "X.class_eval do\ndef a; @x = nil; @x = 2; end\nend\nK = Class.new { def a; @y = nil; @y = 3; end }\n"

      expect(seeds(source)).to eq("C" => { :@x => "1" }, "X" => { :@x => "2" }, "K" => { :@y => "3" })
    end

    # WD3 — a constructor that reassigns the ivar through an unconditional call of a method of its class.
    describe "a call of a method of the same class" do
      it "overwrites when the callee definitely assigns the ivar, on the implicit or `self` receiver" do
        expect(c("def initialize; @m = nil; mask!; end\ndef mask!; @m = 1; end")).to eq(:@m => "1")
        expect(c("def a; @p = nil; self.set_p; end\ndef set_p; @p = 1; end")).to eq(:@p => "1")
      end

      it "does not for a call with a block, on another receiver, of no def, or of a def of another class" do
        body = "def b; @q = nil; set_q { }; end\ndef set_q; @q = 1; end\ndef c; @r = nil; other.set_r; end\n" \
               "def set_r; @r = 1; end\ndef d; @s = nil; unknown; end\ndef e; @t = nil; set_t; end"

        other = "class D; def set_t; @t = 1; end; def unknown; @s = 1; end; end\n"

        expect(seeds("class C\n#{body}\nend\n#{other}").fetch("C"))
          .to eq(:@q => "1?", :@r => "1?", :@s => "nil", :@t => "nil")
      end

      it "does not when the callee may leave the ivar, writes `nil`, or is a singleton-side def" do
        body = "def a; @x = nil; maybe; end\ndef maybe; @x = 1 if c; end\ndef b; @y = nil; clear; end\n" \
               "def clear; @y = nil; end\ndef d; @z = nil; set; end\ndef self.set; @z = 1; end"

        expect(c(body)).to eq(:@x => "1?", :@y => "nil", :@z => "1?")
      end

      it "reads the callee's own body as it reads the caller's: its conditionals, its `case`, its own transient" do
        body = "def a; @x = nil; pick; end\ndef pick\nif c\n@x = 1\nelse\n@x = 2\nend\nend\n" \
               "def b; @y = nil; pick2; end\ndef pick2\ncase v\nwhen 1 then @y = 1\nelse @y = 3\nend\nend\n" \
               "def d; @z = nil; trans; end\ndef trans; @z = nil; @z = 2; end"

        expect(c(body)).to eq(:@x => "1 | 2", :@y => "1 | 3", :@z => "2")
      end

      it "takes the last def of a name, and the defs a block or a write files under the class" do
        source = "class C\ndef a; @y = nil; helper; end\ndef helper; 1; end\ndef helper; @y = 2; end\nend\n" \
                 "class X; end\nX.class_eval do\ndef a; @x = nil; set; end\ndef set; @x = 1; end\nend\n" \
                 "K = Class.new do\ndef a; @k = nil; set; end\ndef set; @k = 1; end\nend\n"

        expect(seeds(source)).to eq("C" => { :@y => "2" }, "X" => { :@x => "1" }, "K" => { :@k => "1" })
      end

      # A method's summary holds the ivars it writes itself somewhere, so a callee is followed only from a method
      # that writes the ivar too.
      it "credits a callee's callee, for an ivar the callee itself writes somewhere" do
        expect(c("def a; @x = nil; l1; end\ndef l1; @x = 0 if c; l2; end\ndef l2; @x = 1; end")).to eq(:@x => "0 | 1")
        expect(c("def a; @x = nil; l1; end\ndef l1; l2; end\ndef l2; @x = 1; end")).to eq(:@x => "1?")
      end

      it "follows three calls deep and no deeper" do
        chain = lambda do |depth|
          links = (1...depth).map { |i| "def m#{i}; @y = 0 if c; m#{i + 1}; end" }
          c("def a; @y = nil; m1; end\n#{links.join("\n")}\ndef m#{depth}; @y = 1; end").fetch(:@y)
        end

        expect((1..4).map { |depth| chain.call(depth) }).to eq(["1", "0 | 1", "0 | 1", "0 | 1 | nil"])
      end

      it "ends on a cycle of calls with nothing credited" do
        expect(c("def a; @x = nil; ping; end\ndef ping; @x = 0 if c; pong; end\ndef pong; @x = 0 if c; ping; end"))
          .to eq(:@x => "0?")
        expect(c("def a; @x = nil; a; end")).to eq(:@x => "nil")
      end

      it "credits through a conditional or a `case` of the caller whose every arm calls" do
        body = "def a\n@x = nil\nif c\nset\nelse\nset\nend\nend\ndef set; @x = 1; end\n" \
               "def b\n@y = nil\ncase v\nwhen 1 then set_y\nelse set_y\nend\nend\ndef set_y; @y = 2; end"

        expect(c(body)).to eq(:@x => "1", :@y => "2")
      end

      # The method in progress answers no assignment to a call that comes back to it.
      it "answers no assignment for a method a cycle of calls comes back to" do
        body = "def a; b; @x = 1; end\ndef b; a; @x = 2 if c; end\ndef use; @x = nil; b; end"

        expect(c(body)).to eq(:@x => "1 | 2 | nil")
      end

      it "does not when the callee returns before its write" do
        expect(c("def setup; return 0; @x = 1; end\ndef use; @x = nil; setup; end")).to eq(:@x => "1?")
        expect(c("def setup; return if c; @x = 1; end\ndef use; @x = nil; setup; end")).to eq(:@x => "1?")
      end
    end

    it "keeps a write of any other value a later statement overwrites, and a `nil` only an earlier one assigns" do
      expect(c("def m; @x = 1; @x = 2; end")).to eq(:@x => "1 | 2")
      expect(c("def m; @x = 1; @x = nil; foo; end")).to eq(:@x => "1?")
    end

    it "keeps it when a branch assigns nothing: an empty `else`, a value, a `return` before the write" do
      expect(c("def m; @x = nil; if c; @x = 1; else; end; end")).to eq(:@x => "1?")
      expect(c("def m; @x = nil; if c; 1; else; @x = 1; end; end")).to eq(:@x => "1?")
      expect(c("def m; @x = nil; if c; return; @x = 1; else; @x = 2; end; end")).to eq(:@x => "1 | 2 | nil")
    end
  end

  # A shape carrier a method mutates in place holds, at every other method's entry, what the mutations left in it.
  describe "an entry the class mutates in place" do
    it "widens a tuple, a hash shape, a String literal and a Set literal under a mutator of its own family" do
      body = "def initialize; @t = [1]; @h = { a: 1 }; @s = \"ab\"; @set = Set[\"a\"]; end\n" \
             "def a; @t << 2; @h[:b] = 2; @s << \"c\"; @set << 1; end"

      expect(c(body)).to eq(:@t => "Array[Dynamic[top]]", :@h => "Hash[Dynamic[top], Dynamic[top]]", :@s => "String",
                            :@set => "Set[Dynamic[top]]")
    end

    it "leaves an entry no mutator of its family is called on, and any other type" do
      body = "def initialize; @t = [1]; @h = { a: 1 }; @s = \"ab\"; @set = Set[1]; @n = 1; @u = [2]; end\n" \
             "def a; @t.merge(1); @h.push(1); @s.add(1); @set.push(2); @n.push(1); @u.last; end"

      expect(c(body)).to eq(:@t => "[1]", :@h => "{ a: 1 }", :@s => '"ab"', :@set => "Set[1]", :@n => "1", :@u => "[2]")
    end

    # Issue #2294 — the Set-only names are read against a Set alone: `merge` on a hash returns a new one.
    it "reads a Set-only mutator name against a Set alone" do
      expect(c("def initialize; @h = { a: 1 }; @s = Set[1]; end\ndef a; @h.merge(b: 2); @s.add(2); end"))
        .to eq(:@h => "{ a: 1 }", :@s => "Set[Dynamic[top]]")
    end

    it "widens each member of a union by its own family, and keeps the others" do
      body = "def initialize; @d = [1]; end\ndef reset; @d = \"x\"; end\ndef other; @d = :y; end\n" \
             "def push; @d << 2; end"

      expect(c(body)).to eq(:@d => ":y | Array[Dynamic[top]] | String")
    end

    # `@h[k] ||= v` and its siblings store through `[]=` and are no `[]=` call; an index target stores the same way.
    it "counts an index write of any form as a store" do
      body = "def initialize; @h = { a: 1 }; @i = { a: 1 }; @j = { a: 1 }; @k = { a: 1 }; @l = { a: 1 }; end\n" \
             "def a; @h[:k] ||= 1; @i[:k] &&= 1; @j[:k] += 1; @k[:a], x = 1, 2; end\ndef b; for @l[:a] in xs; end; end"

      expect(c(body).values.uniq).to eq(["Hash[Dynamic[top], Dynamic[top]]"])
    end

    # A hash shape given a default and never stored into keeps its pairs.
    it "opens a hash shape a method gives a default, where no method stores into it" do
      body = "def initialize; @h = { a: 1 }; @g = { a: 1 }; end\ndef a; @h.default = 0; @g.default = 0; @g[:b] = 1; end"

      expect(c(body)).to eq(:@h => "{ a: 1, ... }", :@g => "Hash[Dynamic[top], Dynamic[top]]")
    end

    # `compare_by_identity` on a shape with a String key answers a `Hash`, which a later lookup mutator leaves.
    it "takes each lookup mutator in turn, and stops at one that leaves no shape" do
      body = "def initialize; @g = { \"k\" => 1 }; @i = { a: 1 }; end\n" \
             "def a; @g.compare_by_identity; @g.default = 0; @i.default = 0; @i.default_proc = nil; end"

      expect(c(body)).to eq(:@g => "Hash[String, Dynamic[top] | Integer]", :@i => "{ a: 1, ... }")
    end

    it "sees a mutation in a block, a `define_method` block and a conditional, in any def of the class alone" do
      source = "class C\ndef initialize; @a = [1]; @b = [1]; @c = [1]; @d = [1]; end\n" \
               "def m; [1].each { @a << 2 }; end\n" \
               "define_method(:n) { @b << 2 }\ndef o; @c << 2 if cond; end\nend\nclass D; def m; @d << 2; end; end\n"

      expect(seeds(source)).to eq("C" => { :@a => "Array[Dynamic[top]]", :@b => "Array[Dynamic[top]]",
                                           :@c => "Array[Dynamic[top]]", :@d => "[1]" })
    end

    it "sees a mutation in the predicate of a conditional and in each of its branches" do
      body = "def initialize; @p = [1]; @t = [1]; @e = [1]; @u = [1]; end\n" \
             "def m\nif @p << 1\n@t << 1\nelse\n@e << 1\nend\n@u << 1 unless cond\nend"

      expect(c(body).values.uniq).to eq(["Array[Dynamic[top]]"])
    end
  end

  # An ivar a method returns leaves the object: a mutation of what a self-call returned mutates the ivar.
  describe "an ivar a method hands back" do
    def rows(*methods) = c("def initialize; @a = [1]; @b = [1]; @c = [1]; @d = [1]; end\n#{methods.join("\n")}")

    it "is widened when a method mutates what a self-call of the returning method answers" do
      expect(rows("def bucket; @a; end", "def add(x); bucket << x; end", "def peek; @b; end", "def none; end"))
        .to eq(:@a => "Array[Dynamic[top]]", :@b => "[1]", :@c => "[1]", :@d => "[1]")
    end

    it "is found by an explicit `return` of the ivar alone, anywhere in the body but in a nested def" do
      methods = ["def p1(k)\nreturn 1 if z\nreturn @a if k\n[1].each { return @b }\n{}\nend",
                 "def p2; return @c, 1; end", "def p3\ndef inner; return @d; end\n1\nend",
                 "def m; p1(1) << 1; p2 << 1; p3 << 1; end"]

      expect(rows(*methods))
        .to eq(:@a => "Array[Dynamic[top]]", :@b => "Array[Dynamic[top]]", :@c => "[1]", :@d => "[1]")
    end

    it "is found in the tail of the body through the branches a value comes from" do
      methods = ["def p1(k)\nif k then @a else @b end\nend", "def p2(k)\nunless k then (@c) else begin; @d; end end\n" \
                                                             "end",
                 "def m(k); p1(k) << 1; p2(k) << 1; end"]

      expect(rows(*methods).values.uniq).to eq(["Array[Dynamic[top]]"])
    end

    it "is found through a `case` and an `&&` or `||` tail" do
      methods = ["def p1(k)\ncase k\nwhen 1 then @a\nelse @b\nend\nend", "def p2(k) = k && @c || @d",
                 "def m(k); p1(k) << 1; p2(k) << 1; end"]

      expect(rows(*methods).values.uniq).to eq(["Array[Dynamic[top]]"])
    end

    it "is not found in a value computed from the ivar, a tail that is no ivar, or a `case … in`" do
      methods = ["def p1(k); @a[k]; end", "def p2; @b.dup; end", "def p3(k)\ncase k\nin Integer then @c\nend\nend",
                 "def p4; @d; 1; end", "def m(k); p1(k) << 1; p2 << 1; p3(k) << 1; p4 << 1; end"]

      expect(rows(*methods).values.uniq).to eq(["[1]"])
    end

    # Each pair of parentheses is two nodes deep, the parentheses and the statements in them.
    it "follows a tail eight nodes deep and no deeper" do
      methods = ["def deep = (((@a)))", "def deeper = ((((@b))))", "def m; deep << 1; deeper << 1; end"]

      expect(rows(*methods)).to eq(:@a => "Array[Dynamic[top]]", :@b => "[1]", :@c => "[1]", :@d => "[1]")
    end

    it "counts a mutation on the implicit receiver alone, in any form and at any depth of the body" do
      methods = ["def a; @a; end", "def b; @b; end", "def c; @c; end", "def d; @d; end",
                 "def m(o, k); a[k] ||= 1; [1].each { b << 1 }; o.c << 1; self.d << 1; end"]

      expect(rows(*methods))
        .to eq(:@a => "Array[Dynamic[top]]", :@b => "Array[Dynamic[top]]", :@c => "[1]", :@d => "[1]")
    end

    it "is per class, and asks nothing of a class no method of which returns an ivar" do
      source = "class C\ndef initialize; @a = [1]; end\ndef a; @a; end\nend\n" \
               "class D\ndef initialize; @a = [1]; end\ndef m; a << 1; end\nend\n"

      expect(seeds(source)).to eq("C" => { :@a => "[1]" }, "D" => { :@a => "[1]" })
    end

    it "records the mutator's name: one no carrier of the entry takes widens nothing" do
      expect(rows("def a; @a; end", "def m; a.size; a.default = 1; end")).to include(:@a => "[1]")
    end
  end

  # #541 — a writer declaration is the class's own statement that `@x` takes values from outside.
  describe "an `attr_writer` declaration" do
    it "records each name of an `attr_writer` or `attr_accessor` as unknown, in every spelling Ruby runs on `self`" do
      body = "attr_writer :w\nattr_accessor :a, \"b\"\nattr_reader :r\nprivate attr_writer :p\nself.attr_writer :s\n" \
             "send(:attr_writer, :t)\ndef initialize; @w = nil; @a = 1; @r = nil; end"

      expect(c(body)).to eq(:@w => "Dynamic[top]?", :@a => "1 | Dynamic[top]", :@b => "Dynamic[top]",
                            :@p => "Dynamic[top]", :@s => "Dynamic[top]", :@t => "Dynamic[top]", :@r => "nil")
    end

    it "records it under the class a block or a write gives the call, and nowhere for no class" do
      source = "class C\nclass << self\nattr_accessor :s\nend\nend\nK = Class.new { attr_writer :k }\n" \
               "attr_writer :top\nclass X; end\nX.class_eval { attr_writer :e }\nX.instance_eval { attr_writer :i }\n" \
               "Class.new { attr_writer :anon }\n"

      expect(seeds(source))
        .to eq("K" => { :@k => "Dynamic[top]" }, "X" => { :@e => "Dynamic[top]", :@i => "Dynamic[top]" })
    end
  end

  # #1768 — a literal `define_method` block on the implicit or `self` receiver is an instance method body.
  describe "a `define_method` block" do
    it "is walked as an instance body of the class, on the implicit or `self` receiver, with a literal block" do
      body = "define_method(:m) { @x = self }\nself.define_method(:p) { @p = 1 }\ndefine_method(:n, &blk)\n" \
             "define_method(:o, callable)\nother.define_method(:q) { @q = 1 }\ndefine_method(:r) { }"

      expect(c(body)).to eq(:@x => "C", :@p => "1")
    end

    it "is gathered as a def body: every write form, the mutations, and the defs the walk reaches in it" do
      body = "def initialize; @t = [1]; end\ndefine_method(:m) do\n@t << 2\ndef inner; @no = 1; end\n" \
             "instance_variable_set(:@refl, 1)\n@a, @b = 1, 2\n@c ||= 3\nend"

      expect(c(body))
        .to eq(:@t => "Array[Dynamic[top]]", :@refl => "1", :@a => "1", :@b => "2", :@c => "3?", :@no => "1")
    end

    it "is typed under the chain of the class it is in" do
      expect(seeds("module M\nclass C\ndefine_method(:m) { @a = Bar.new }\nend\nend\n", bars))
        .to eq("M::C" => { :@a => "M::Bar" })
    end

    # An ADR-16 `block_as_methods:` call whose entry binds the receiver's instance takes the same arm.
    it "is joined by a plugin's `block_as_methods` call on the implicit or `self` receiver of a class it covers" do
      entry = Rigor::Plugin::Macro::BlockAsMethod.new(receiver_constraint: "App", method_names: %i[get])
      source = "class App\n@x = nil\nget('/') { @x = 'a' }\nput('/') { @y = 1 }\nx.get('/') { @z = 1 }\n" \
               "self.get('/') { @w = 1 }\nget('/')\ndef use; @x; end\nend\nclass Other; get('/') { @o = 1 }; end\n"

      expect(seeds(source)).to eq({})
      expect(seeds(source, plugin_scope(block_as_methods: [entry]))).to eq("App" => { :@x => '"a"?', :@w => "1" })
    end

    # The class-body exemption is taken back for every ivar the block writes, in any write form, and for none that a
    # def nested in the block writes.
    it "takes back the class-body exemption for each write form in the block, and for no write of a def in it" do
      body = "@b = 0; @c = 0; @d = 0; @e = 0; @f = 0; @x = 0\n" \
             "define_method(:m) { @b &&= 1; @c += 1; @d, y = 1, 2; instance_variable_set(:@e, 1); @f ||= false }\n" \
             "define_method(:n) { def inner; @x = 1; end }\n" \
             "def r; @b; @c; @d; @e; @f; @x; end\ndef w; @b = 1; @f = 1; end"

      expect(c(body)).to eq(:@d => "1?", :@e => "1?", :@b => "1?", :@c => "Integer?", :@f => "1?", :@x => "1")
    end

    it "is walked under the class an eval-family block names, with no header around it" do
      expect(seeds("X.class_eval { define_method(:m) { @b = 1 } }\n")).to eq("X" => { :@b => "1" })
    end
  end

  # Issue #2488 — `E.attr_writer :w` and `E.define_method(:m) { … }` are `E`'s, wherever they are written.
  describe "a writer call on a receiver" do
    it "records an `attr_writer` family call under the class its receiver names, and walks a `define_method` block" do
      source = "class E; end\nclass C\nE.attr_writer :w\nE.send(:attr_accessor, :x)\n" \
               "E.define_method(:m) { @y = self }\n" \
               "E.attr_reader :r\nx.attr_writer :dyn\nself::F.attr_writer :f\nend\nE.attr_writer :top\n"

      expect(seeds(source)).to eq(
        "E" => { :@w => "Dynamic[top]", :@x => "Dynamic[top]", :@y => "E", :@top => "Dynamic[top]" },
        "C::F" => { :@f => "Dynamic[top]" }
      )
    end

    it "records a `define_method` block's mutations and takes back a class-body exemption, as one in the body does" do
      source = "class E\n@z = nil\ndef initialize; @t = [1]; end\ndef use; @z; end\nend\n" \
               "E.define_method(:m) { @t << 2; @z = 1 }\nE.define_method(:n)\n"

      expect(seeds(source)).to eq("E" => { :@t => "Array[Dynamic[top]]", :@z => "1?" })
    end

    it "resolves the receiver as an eval-family receiver: a `self::` path below `class <<` names nothing" do
      source = "class E; end\nclass C\nclass << self\nE.attr_writer :w\nself::G.attr_writer :g\nend\nend\n"

      expect(seeds(source)).to eq("E" => { :@w => "Dynamic[top]" })
    end

    it "types a `define_method` block under the chain of the class its receiver names" do
      expect(seeds("module M\nclass E; end\nE.define_method(:m) { @a = Bar.new }\nend\n", bars))
        .to eq("M::E" => { :@a => "M::Bar" })
    end

    it "walks the call's children once it is recorded: a def in the block is the class's around the call" do
      expect(c("C.define_method(:m) { def inner; @q = 1; end }")).to eq(:@q => "1")
    end
  end

  # The table the definite-assignment summary reads, and the census of the ivars a method hands back: per class, the
  # instance `def`s by name.
  describe "the table of instance defs" do
    define_method(:defs) do |source|
      described_class.send(:collect_class_method_defs, parse(source)).transform_values(&:keys)
    end

    it "files each instance def under the class its header names, the last def of a name, and no singleton-side def" do
      source = "class C; def a; end; def self.s; end; def a; 1; end; class << self; def t; end; end; end\n" \
               "def top; end\n" \
               "module M; class N; def n; end; end; class ::R; def r; end; end; class A::B; def b; end; end; end\n"
      table = described_class.send(:collect_class_method_defs, parse(source))

      expect(table.transform_values(&:keys)).to eq("C" => [:a], "M::N" => [:n], "R" => [:r], "M::A::B" => [:b])
      expect(table.fetch("C").fetch(:a).body.slice).to eq("1")
    end

    it "answers the table it is handed, for a node and for none, and files under the prefix it is handed" do
      table = { "seed" => {} }

      expect(described_class.send(:collect_class_method_defs, nil, [], table)).to equal(table)
      expect(described_class.send(:collect_class_method_defs, parse("class C; def a; end; end"), %w[P], table))
        .to equal(table)
      expect(table.keys).to eq(%w[seed P::C])
    end

    it "walks into a def's body, a block and a conditional: a def there is the class's too" do
      expect(defs("class C; def a; def inner; end; end; [1].each { def blk; end }; if x then def cond; end end; end\n"))
        .to eq("C" => %i[a blk cond])
    end

    it "walks a header's body, never its superclass, and a header with no body is nothing" do
      expect(defs("module M\nclass C < (def helper; end; Base)\ndef a; end\nend\nclass D; end\nend\n"))
        .to eq("M::C" => [:a])
    end

    it "files the defs of a class-creating write's block under the class the write names" do
      source = "K = Class.new { def k; end }\nclass C\nL = Class.new(Base) { def l; end }\n" \
               "M::N = Class.new { def n; end }\n" \
               "O ||= Class.new { def o; end }\nP = Class.new((def h; end; Object)) { def p; end }\nQ = Class.new\n" \
               "R = (def h2; end; 1)\nend\n"

      expect(defs(source)).to eq("K" => [:k], "C::L" => [:l], "C::M::N" => [:n], "C::O" => [:o], "C" => %i[h h2],
                                 "C::P" => [:p])
    end

    it "files the defs of a class-creating call no write names nowhere, and its arguments' around it" do
      expect(defs("class C\nClass.new { def anon; end }\nClass.new((def h; end; Object)) { def anon2; end }\n" \
                  "Class.new((def h2; end; Object))\nend\n")).to eq("C" => %i[h h2])
    end

    it "files an eval-family block's defs under its receiver, and an `instance_eval` block's nowhere" do
      source = "class X; end\nclass C\nX.class_eval { def a; end }\nX.instance_eval { def b; end }\n" \
               "class_eval { def c; end }\n" \
               "x.class_eval { def d; end }\nX.class_eval((def h; end)) { def e; end }\n" \
               "self::Y.class_eval { def f; end }\n" \
               "X.class_eval { }\nend\nX.class_exec { def g; end }\nclass_eval { def top; end }\n"

      expect(defs(source)).to eq("X" => %i[a e g], "C" => %i[c h], "C::Y" => [:f])
    end

    it "walks an eval-family call's receiver and arguments on the side it is on" do
      expect(defs("class X; end\nX.instance_eval { X.class_eval((def h; end)) { def a; end } }\n")).to eq("X" => [:a])
    end

    it "anchors a `self::` header on the rebound self around it, and keeps a bare one lexical" do
      source = "class C\nclass self::S; def s; end; end\nK = Class.new do\nclass self::T; def t; end; end\n" \
               "class U; def u; end; end\nend\nX.class_eval do\nclass self::V; def v; end; end\nend\nend\n"

      expect(defs(source)).to eq("C::S" => [:s], "C::K::T" => [:t], "C::U" => [:u], "X::V" => [:v])
    end

    it "files nothing below `class <<` but under a name a rooted header, a path write or a receiver gives" do
      source = "class C\nclass << self\nclass D; def d; end; end\nclass ::E; def e; end; end\n" \
               "K = Class.new { def k; end }\n::L = Class.new { def l; end }\nX.class_eval { def x; end }\n" \
               "class_eval { def y; end }\nClass.new { def z; end }\nend\n" \
               "class << (class F; def f; end; self; end); end\nend\n"

      expect(defs(source)).to eq("E" => [:e], "L" => [:l], "X" => [:x], "C::F" => [:f])
    end

    # Moved from scope_indexer_spec.rb (ADR-116 C4), where it called the function on the indexer.
    it "files `class D` method defs under `class <<` nowhere in the class-def table" do
      defs = described_class.send(:collect_class_method_defs, parse(<<~RUBY))
        class C
          class << self
            class D
              def m; end
            end
          end
        end
      RUBY
      expect(defs).not_to have_key("C::D")
    end

    it "files the defs of a path or-write's block under the class the write names" do
      expect(defs("M::Q ||= Class.new { def q; end }\n")).to eq("M::Q" => [:q])
    end

    it "keeps a header inside an anonymous class's block lexical" do
      expect(defs("class C\nClass.new { class Inner; def i; end; end }\nend\n")).to eq("C::Inner" => [:i])
    end

    it "files a def in a call's receiver or arguments under the class a block around the call names" do
      source = "K = Class.new do\nClass.new((def a; end; Object)) { }\n(def b; end; X).class_eval { }\n" \
               "L = Class.new((def c; end; Object)) { }\nend\n"

      expect(defs(source)).to eq("K" => %i[a b c])
    end

    it "files no def in an anonymous call's arguments on the singleton side of an `instance_eval` block" do
      expect(defs("class X; end\nX.instance_eval { Class.new((def helper; end; Object)) { } }\n")).to eq({})
    end

    it "keeps the unnameable cref below `class <<` through each shape's parts and body" do
      source = "class C\nclass << self\nclass << (class A; def a; end; end; self)\nend\n" \
               "Class.new((class B; def b; end; end; Object)) { class B2; def b2; end; end }\n" \
               "(class D; def d; end; end; X).class_eval { class D2; def d2; end; end }\n" \
               "K = Class.new((class E; def e; end; end; Object)) { class E2; def e2; end; end }\n" \
               "class F\nclass G; def g; end; end\nself::Y.class_eval { def y; end }\n" \
               "X.class_eval { def n; end }\nend\nend\nend\n"

      expect(defs(source)).to eq("X" => [:n])
    end

    it "names a `self::` write below `class <<` under the class a block around it names" do
      source = "class C\nclass << self\n::L = Class.new { self::W = Class.new { def w; end } }\nend\nend\n"

      expect(defs(source)).to eq("L::W" => [:w])
    end

    it "anchors a `self::` header on the class a block names below `class <<`, and on none an anonymous one gives" do
      named = "class C\nclass << self\n::L = Class.new { class self::In; def m; end; end }\nend\nend\n"
      anonymous = "Class.new { self::Y.class_eval { def y; end }\nclass self::In\nclass Deep; def m; end; end\nend }\n"

      expect(defs(named)).to eq("L::In" => [:m])
      expect(defs(anonymous)).to eq({})
    end

    # The write is answered for whole, so what its target hangs off is not walked: a def there is filed nowhere.
    it "answers for a class-creating write whole, its block empty or not: what a path target hangs off is not walked" do
      expect(defs("class C\n(def h; end; M)::K = Class.new { }\n(def i; end; M)::L = Class.new { def l; end }\nend\n"))
        .to eq({})
    end
  end

  # What another file of `lib/` calls: `ScopeIndexer.index`. A second name here is a new way into the module. Four
  # constants are public: the two `ClassCvarCensus` reads by a path, and the two that were public on the indexer.
  it "exposes the entry alone, and four constants" do
    expect(described_class.singleton_methods(false)).to eq([:build_class_ivar_index])
    expect(described_class.constants(false).sort)
      .to eq(%i[ATTR_WRITER_MACROS BindingTargets IVAR_BARRIER_NODES MethodEffectResolver])
    expect(described_class::IVAR_BARRIER_NODES).to eq([Prism::DefNode, Prism::ClassNode, Prism::ModuleNode])
    expect(described_class::ATTR_WRITER_MACROS).to eq(%i[attr_writer attr_accessor])
  end

  it "leaves none of its 99 functions and none of its 18 constants on ScopeIndexer" do
    functions = described_class.private_instance_methods(false)
    constants = %i[IVAR_WRITE_NODES IVAR_BARRIER_NODES EMPTY_GUARDED_IVARS EMPTY_IVAR_SET TAIL_VALUE_DEPTH_CAP
                   SAME_CLASS_CALL_DEPTH_CAP MethodEffectResolver OPERATOR_CHAIN_UNION_CAP AND_WRITE_CONTRIBUTIONS
                   OPERATOR_WRITE_CONTRIBUTIONS DEFINE_METHOD_WRITES CLASS_BODY_WRITES REFLECTIVE_OPAQUE_CLASSES
                   CONSTANT_IVAR_VALUES SINGLETON_IVAR_WRITES BindingTargets ATTR_WRITER_MACROS OBJECT_CODE_BARRIERS]

    expect(functions.size).to eq(99)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
    expect(constants.select { |name| indexer.const_defined?(name, false) }).to eq([])
    expect(constants.reject { |name| described_class.const_defined?(name, false) }).to eq([])
  end

  # The #3318 cut-off counts the functions a moved cluster calls back in what stays, and allows four. This one calls
  # four recognisers the other walkers ask too, and the census scope, a module of its own, at four sites.
  it "calls four functions of the indexer, at one site each, and the census scope at four" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/class_ivar_index.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      receiver = DeclarationFactSources.constant_name(node.receiver) if node.is_a?(Prism::CallNode)
      [receiver, node.name] if %w[ScopeIndexer CensusScope].include?(receiver)
    end

    expect(calls.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }).to eq(
      "ScopeIndexer" => %i[attr_macro def_receiver_targets_lexical_self? each_attr_macro_name def_side],
      "CensusScope" => %i[census_body_scope census_body_scope census_body_scope census_body_scope]
    )
  end

  # `BindingTargets` reads a `rescue =>` reference or a `for` index for the targets of one class: the ivar census
  # asks for ivar targets, the class-variable census for class-variable ones.
  describe "BindingTargets" do
    def statement(source) = parse(source).statements.body.first

    it "names the targets of a class a `for` index binds, through a splat and a nested index" do
      node = statement("for (@a, @@b), *@c, d in xs; end")

      expect(described_class::BindingTargets.names(node, Prism::InstanceVariableTargetNode)).to eq(%i[@a @c])
      expect(described_class::BindingTargets.names(node, Prism::ClassVariableTargetNode)).to eq([:@@b])
      expect(described_class::BindingTargets.names(statement("for *@a in xs; end"), Prism::InstanceVariableTargetNode))
        .to eq([:@a])
    end

    it "names the reference of a rescue clause, and nothing for any other node" do
      clause = statement("begin; rescue E => @e; end").rescue_clause
      none = described_class::BindingTargets.names(statement("@a = 1"), Prism::InstanceVariableTargetNode)

      expect(described_class::BindingTargets.names(clause, Prism::InstanceVariableTargetNode)).to eq([:@e])
      expect(described_class::BindingTargets.names(clause, Prism::ClassVariableTargetNode)).to eq([])
      expect(described_class::BindingTargets.names(statement("begin; rescue E; end").rescue_clause, Prism::Node))
        .to eq([])
      expect([none, none.frozen?]).to eq([[], true])
    end

    it "types a rescue reference as the clause's exception and a `for` index as unknown" do
      clause = statement("begin; rescue ArgumentError => @e; end").rescue_clause

      expect(described_class::BindingTargets.value_type(clause, empty).describe).to eq("ArgumentError")
      expect(described_class::BindingTargets.value_type(statement("for @a in xs; end"), empty).describe)
        .to eq("Dynamic[top]")
    end
  end

  # A fresh child under the bundle: the file requires the dispatcher, and so the `rbs` gem, which the unbundled
  # child the other mirror specs load their file in (`RubyRun`) does not have.
  def bundled_ruby(source)
    root = DeclarationFactSources::REPO_ROOT
    Open3.capture3({ "BUNDLE_GEMFILE" => File.join(root, "Gemfile") }, RbConfig.ruby, "-rbundler/setup", "-I",
                   File.join(root, "lib"), "-e", source)
  end

  # The module calls four functions of `ScopeIndexer` and reads its `INSTANCE_EVAL_CALLS`, all of which
  # `scope_indexer.rb` defines: the file requires what else it names, and until the indexer has loaded only a call
  # that reaches none of the five answers. It names no `Scope`: the one it is handed is the caller's.
  def alone_probe
    <<~RUBY
      require "rigor/inference/scope_indexer/class_ivar_index"
      indexer = Rigor::Inference::ScopeIndexer
      index = indexer::ClassIvarIndex
      inference = Rigor::Inference
      named = %i[CensusScope ConstantIvarValue DeclaredIvarTypes DeclaredParamWrites EmptySeed IvarContributions]
              .map { |name| indexer.const_defined?(name, false) }
      named += %i[CensusForeignBlock DefineMethodBlockSelf ErrorInfo HashLookupMutation IndexWriteWidening
                  MacroBlockSelfType MethodDispatcher MultiTargetBinder MutationWidening Narrowing ReceiverWriterCall
                  ReflectiveIvarWrite SetMutation StringMutation].map { |name| inference.const_defined?(name, false) }
      named += [inference::DeclarationWalk.const_defined?(:Rules, false),
                Rigor::Type.const_defined?(:Combinator, false), Rigor::Source.const_defined?(:ConstantPath, false),
                Prism::ProgramNode.method_defined?(:rigor_each_child),
                inference::MethodDispatcher.respond_to?(:dispatch)]
      absent = defined?(Rigor::Scope)
      require "rigor/scope"
      failure = lambda do |&call|
        call.call
      rescue NameError => e
        [e.class.name, e.name]
      end
      scope = Rigor::Scope.empty
      built = ->(source) { failure.call { index.build_class_ivar_index(Prism.parse(source).value, scope) } }
      defs = ->(source) { failure.call { index.send(:collect_class_method_defs, Prism.parse(source).value).keys } }
      answers = [built.call("class C; X = 1; def e; end; end\\ndef top; @a = 1; end"),
                 built.call("class C; def m; @a = 1; end; end"), built.call("class C; foo; end"), built.call("foo"),
                 built.call("X.class_eval { 1 }"), defs.call("class C; def m; end; end"),
                 defs.call("X.class_eval { def m; end }")]
      print [indexer.respond_to?(:index), named.uniq, absent, answers].inspect
    RUBY
  end

  it "loads without the indexer, with what it names, and answers only what needs nothing of the indexer" do
    out, err, status = bundled_ruby(alone_probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, [true], nil, [{}, ["NoMethodError", :def_side], ["NoMethodError", :attr_macro], ' \
                      '["NoMethodError", :attr_macro], ["NameError", :INSTANCE_EVAL_CALLS], ["C"], ' \
                      '["NameError", :INSTANCE_EVAL_CALLS]]]')
  end

  describe "its callers" do
    it "is the `class_ivars` table `ScopeIndexer.index` seeds" do
      program = parse("class C\ndef initialize; @a = 1; end\ndef use; @b.x; end\ndef set; @b = :s; end\nend\n")
      scope = indexer.index(program, default_scope: empty)[program]

      expect(scope.class_ivars_for("C").transform_values(&:describe)).to eq(:@a => "1", :@b => ":s?")
    end

    it "is built once a file, on the root and with the declarations `index` is told to read" do
      allow(described_class).to receive(:build_class_ivar_index).and_call_original
      program = parse("class C; def a; @a = 1; end; end\n")
      indexer.index(program, default_scope: empty, declared_ivar_types: false)

      expect(described_class).to have_received(:build_class_ivar_index)
        .once.with(program, an_instance_of(Rigor::Scope), declared_ivar_types: false)
    end

    it "is what the class-variable census reads its barriers and its target names from" do
      source = "class C\ndef m\ndef inner; @@no = 1; end\nfor @@x in xs; end\n@@a = 1\nend\nend\n"
      table = indexer::ClassCvarCensus.build_class_cvar_index(parse(source), empty)

      expect(table.transform_values { |entries| entries.transform_values(&:describe) })
        .to eq("C" => { :@@x => "Dynamic[top]", :@@a => "1" })
    end
  end
end
