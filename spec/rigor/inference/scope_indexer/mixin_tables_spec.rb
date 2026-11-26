# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::MixinTables` builds the include and prepend tables of one file. The examples
# hand `mixin_tables` a parsed snippet and read the three tables back: no index is built and no body evaluated,
# apart from the examples that pin the callers. The examples that read the include table beside the extend table,
# the methods table or a scope stay in `scope_indexer_spec.rb`.
RSpec.describe Rigor::Inference::ScopeIndexer::MixinTables do
  let(:indexer) { Rigor::Inference::ScopeIndexer }
  let(:empty) { Rigor::Scope.empty }

  def parse(source)
    Prism.parse(source).value
  end

  def tables(source) = described_class.mixin_tables(parse(source))

  def includes(source) = tables(source).fetch(:includes)

  def prepends(source) = tables(source).fetch(:prepends)

  # The edges whose order is not a fact: `{owner => {side => names}}`.
  def unpositioned(source) = tables(source).fetch(:unpositioned)

  # What an owner side lists when its order is unknown, and when its set of modules is unknown too.
  def wildcard = ["*"]

  def unnamed = ["*", "?"]

  def toplevel = Rigor::Inference::ObjectMixins::TOPLEVEL_INCLUDE_KEY

  describe "the three tables" do
    it "answers the includes, the prepends and the unpositioned edges of one descent, each frozen" do
      answer = tables("class C\n  include M\n  prepend P\n  def x; include U; end\nend\n")

      expect(answer).to eq(includes: { "C" => %w[P U M] }, prepends: { "C" => ["P"] },
                           unpositioned: { "C" => { include: ["U"] } })
      expect(answer.values).to all(be_frozen)
      expect(answer.fetch(:includes).values + answer.fetch(:prepends).values).to all(be_frozen)
    end

    it "is three empty tables for a program that mixes nothing in, and for no node" do
      expect(tables("class C; def m; end; end\nx = 1\n")).to eq(includes: {}, prepends: {}, unpositioned: {})
      expect(described_class.mixin_tables(nil)).to eq(includes: {}, prepends: {}, unpositioned: {})
      expect(tables("x = 1\n").fetch(:unpositioned)).to equal(indexer::MixinAccumulator::EMPTY)
    end

    it "is each table the two builders answer" do
      root = parse("class C\n  include M\n  prepend P\nend\n")

      expect(described_class.send(:build_discovered_includes, root)).to eq("C" => %w[P M])
      expect(described_class.send(:build_discovered_prepends, root)).to eq("C" => ["P"])
    end
  end

  describe "the two lists of a class" do
    # The include table is the set of modules a class carries, in instance-ancestor search order (#1173).
    it "lists the prepends ahead of the includes in the include table, and alone in the prepend table" do
      source = "class C\n  include I\n  prepend P\n  include J\nend\n"

      expect(includes(source)).to eq("C" => %w[P J I])
      expect(prepends(source)).to eq("C" => ["P"])
    end

    it "drops a class with no name of the kind" do
      source = "class A\n  include I\nend\nclass B\n  prepend P\nend\nclass C\n  extend E\nend\n"

      expect(includes(source)).to eq("A" => ["I"], "B" => ["P"])
      expect(prepends(source)).to eq("B" => ["P"])
    end

    it "puts a later statement nearer, and keeps one statement's arguments in their order" do
      expect(includes("class C\n  include A, B\n  include D\nend\n")).to eq("C" => %w[D A B])
      expect(prepends("class C\n  prepend A, B\n  prepend D\nend\n")).to eq("C" => %w[D A B])
    end

    # A re-`include` is a runtime no-op, so the name keeps its first position.
    it "keeps a repeated `include` where it first stood" do
      expect(includes("class C\n  include A\n  include B\n  include A\nend\n")).to eq("C" => %w[B A])
    end

    it "keeps every statement of a repeated `prepend` in the prepend table, and the name once in the include table" do
      source = "class C\n  prepend A\n  prepend B\n  prepend A\nend\n"

      expect(prepends(source)).to eq("C" => %w[A B A])
      expect(includes(source)).to eq("C" => %w[A B])
    end

    # `include M; prepend M` is Ruby's `[M, C, M]`, which the two tables cannot hold.
    it "names the instance side unpositioned when one module is both included and prepended" do
      expect(tables("class C\n  include M\n  prepend M\nend\n"))
        .to eq(includes: { "C" => ["M"] }, prepends: { "C" => ["M"] }, unpositioned: { "C" => { include: wildcard } })
      expect(unpositioned("class C\n  prepend M\n  include M\nend\n")).to eq("C" => { include: wildcard })
      expect(unpositioned("class C\n  prepend M\n  include N\nend\n")).to eq({})
    end

    it "joins the lists of a class a file opens twice, the later body nearer" do
      expect(includes("class C\n  include A\nend\nclass C\n  include B\nend\n")).to eq("C" => %w[B A])
    end

    it "spells each module as it is written" do
      expect(includes("class C\n  include A::M, ::N\nend\n")).to eq("C" => %w[A::M N])
    end
  end

  describe "a class or module header" do
    it "files a mixin under the class or module whose body holds it, by its qualified name" do
      expect(includes("module Mo\n  include M\nend\n")).to eq("Mo" => ["M"])
      expect(includes("module A\n  class B\n    include M\n  end\nend\n")).to eq("A::B" => ["M"])
      expect(includes("class A::B\n  include M\nend\n")).to eq("A::B" => ["M"])
      expect(includes("module A\n  class ::B\n    include M\n  end\nend\n")).to eq("B" => ["M"])
    end

    it "files nothing for a body with no mixin, and for a header with no body" do
      expect(includes("class C; end\nmodule A\n  class B\n    def m; end\n  end\nend\n")).to eq({})
    end

    it "anchors a `self::` header on the body it is written in" do
      expect(includes("class C\n  class self::D\n    include M\n  end\nend\n")).to eq("C::D" => ["M"])
    end

    it "does not walk the superclass of a header, with a body or with none" do
      expect(includes("class C < (include S; Base)\n  include M\nend\n")).to eq("C" => ["M"])
      expect(includes("class Outer\n  class C < (include S; Base); end\nend\n")).to eq({})
    end

    # The body is walked once, under the class it opens, whatever its walk answers.
    it "files a body with a `rescue` clause under its own class alone" do
      expect(includes("module A\n  class B\n    include M\n  rescue StandardError\n    nil\n  end\nend\n"))
        .to eq("A::B" => ["M"])
    end

    it "files a header through a base nothing names under the name it renders" do
      expect(includes("class C\n  class x::D\n    include M\n  end\nend\n")).to eq("C::D" => ["M"])
    end

    it "anchors a `self::` header on the receiver of the block it is written in" do
      expect(includes("class Outer\n  Recv.class_eval { class self::D; include M; end }\nend\n"))
        .to eq("Recv::D" => ["M"])
    end
  end

  describe "where a mixin call is written" do
    # A direct statement of a body that is itself a direct statement runs where it is written.
    it "positions a mixin that is a direct statement of a direct body" do
      expect(unpositioned("class C\n  include M\n  prepend P\nend\n")).to eq({})
      expect(unpositioned("module A\n  class B\n    include M\n  end\nend\n")).to eq({})
    end

    it "records a mixin in a method, a block or a conditional, and names it unpositioned" do
      ["def m\n    include M\n  end", "def self.m\n    include M\n  end", "[1].each { include M }",
       "include M if x", "x = include(M)", "foo(include(M))", "include(M).bar"].each do |statement|
        expect(tables("class C\n  #{statement}\nend\n"))
          .to include(includes: { "C" => ["M"] }, unpositioned: { "C" => { include: ["M"] } }), statement
      end
    end

    it "names every mixin of a body unpositioned when the declaration is no direct statement" do
      expect(unpositioned("if x\n  class C\n    include M\n  end\nend\n")).to eq("C" => { include: ["M"] })
      expect(unpositioned("foo do\n  class C\n    include M\n  end\nend\n")).to eq("C" => { include: ["M"] })
      expect(unpositioned("if x\n  module A\n    class B\n      include M\n    end\n  end\nend\n"))
        .to eq("A::B" => { include: ["M"] })
    end

    it "names an edge written both ways unpositioned" do
      expect(unpositioned("class C\n  include M\n  def x; include M; end\nend\n")).to eq("C" => { include: ["M"] })
    end
  end

  describe "the spelling of a mixin call" do
    it "records `self.include`, and a `send` of a literal name on the lexical self, as a bare call (#2995)" do
      expect(tables("class C\n  self.include M\nend\n")).to include(includes: { "C" => ["M"] }, unpositioned: {})
      expect(tables("class C\n  send(:include, M)\n  public_send(:prepend, P)\n  __send__('include', N)\nend\n"))
        .to eq(includes: { "C" => %w[P N M] }, prepends: { "C" => ["P"] }, unpositioned: {})
      expect(includes("class C\n  self.send(:include, M)\nend\n")).to eq("C" => ["M"])
    end

    it "records nothing in these tables for an `extend`, or a mixin on the singleton" do
      expect(tables("class C\n  extend E\n  singleton_class.include M\nend\n"))
        .to eq(includes: {}, prepends: {}, unpositioned: {})
    end

    # The call form puts the module in the receiver's ancestry as the declaration form does (#1123, #1722), and
    # runs wherever it is called from.
    it "files a call on a constant under the class it names, unpositioned" do
      expect(tables("class Base; end\nBase.prepend(Loud)\n"))
        .to eq(includes: { "Base" => ["Loud"] }, prepends: { "Base" => ["Loud"] },
               unpositioned: { "Base" => { include: ["Loud"] } })
      expect(tables("class C\n  Base.include(M)\nend\n"))
        .to include(includes: { "Base" => ["M"] }, unpositioned: { "Base" => { include: ["M"] } })
      expect(includes("Integer.send(:include, Ext)\n")).to eq("Integer" => ["Ext"])
    end

    it "resolves a constant receiver through the nesting it is written in" do
      expect(includes("module Api\n  class C; end\n  C.include(T)\nend\n")).to eq("Api::C" => ["T"])
    end

    it "records nothing, and taints nothing, for a call on an object of its own" do
      expect(tables("klass = Class.new\nklass.prepend(T)\nclass C\n  obj.include(T)\nend\n"))
        .to eq(includes: {}, prepends: {}, unpositioned: {})
    end

    # A call the tables cannot hold still reshapes the ancestry: the owner side is tainted, and lists the unnamed
    # marker where its set of modules is unknown (#2991).
    it "taints the owner for a mixin whose argument is no constant, and records none" do
      ["include helper", "include(*MODS)", "prepend helper"].each do |statement|
        expect(tables("class C\n  #{statement}\nend\n"))
          .to eq(includes: {}, prepends: {}, unpositioned: { "C" => { include: unnamed } }), statement
      end
      expect(unpositioned("class C\n  K.include helper\nend\n")).to eq("K" => { include: unnamed })
    end

    it "records the constants of a call that also holds a name it cannot read, and taints the owner" do
      expect(tables("class C\n  include M, helper\nend\n"))
        .to include(includes: { "C" => ["M"] }, unpositioned: { "C" => { include: unnamed } })
      expect(tables("class C\n  K.prepend M, helper\nend\n"))
        .to eq(includes: { "K" => ["M"] }, prepends: { "K" => ["M"] }, unpositioned: { "K" => { include: unnamed } })
    end

    it "taints the order alone for a `Module.new` argument" do
      expect(tables("class C\n  include Module.new { def x; end }\nend\n"))
        .to include(includes: {}, unpositioned: { "C" => { include: wildcard } })
    end

    it "taints the instance side for a `send` whose name is computed (#3006)" do
      expect(tables("class C\n  send(m, M)\nend\n"))
        .to eq(includes: {}, prepends: {}, unpositioned: { "C" => { include: unnamed } })
      expect(unpositioned("class C\n  m = :attr_reader\n  send(m, :x)\nend\n")).to eq({})
      expect(unpositioned("class C\n  m = :extend\n  send(m, X)\nend\n")).to eq({})
    end

    it "taints both sides for an eval block on a receiver nothing names that mixes in" do
      expect(tables("class Outer\n  x.class_eval { include T }\nend\n"))
        .to eq(includes: {}, prepends: {}, unpositioned: { "Outer" => { include: unnamed, extend: wildcard } })
      expect(unpositioned("class Outer\n  x.class_eval { foo }\nend\n")).to eq({})
    end
  end

  describe "a `class <<` body" do
    # `class << self; include M; end` mixes M into the singleton, which the extend tables hold (#728, #915).
    it "records nothing for a mixin written directly in it" do
      expect(tables("class C\n  class << self\n    include M\n    prepend P\n  end\nend\n"))
        .to eq(includes: {}, prepends: {}, unpositioned: {})
    end

    it "walks the expression in the context around it" do
      expect(includes("class C\n  class << (include M; self)\n  end\nend\n")).to eq("C" => ["M"])
      expect(includes("class C\n  class << (K.include M; self)\n  end\nend\n")).to eq("K" => ["M"])
    end

    # The expression of a `class <<` written where `self` or the cref names nothing keeps both.
    it "walks the expression under the self and the cref around it, nameable or not" do
      under_self = "Class.new { class << (self::X.class_eval { include T }; self); end }\n"
      under_cref = "class C\n  class << self\n    class << (class D; include M; end; self)\n    end\n  end\nend\n"

      expect(includes(under_self)).to eq({})
      expect(includes(under_cref)).to eq({})
    end

    it "goes on with the body it is written in" do
      expect(includes("class C\n  class << self; end\n  include M\nend\n")).to eq("C" => ["M"])
    end

    it "files nothing for a bare or `self::` header below it, and a path header by its name" do
      nested = lambda do |header|
        includes("class C\n  class << self\n    #{header}\n      include M\n    end\n  end\nend\n")
      end

      expect(nested.call("class D")).to eq({})
      expect(nested.call("class self::D")).to eq({})
      expect(nested.call("class ::D")).to eq("D" => ["M"])
      expect(nested.call("class A::D")).to eq("C::A::D" => ["M"])
    end

    # A bare header there opens a body no name reaches: what is below it starts from no prefix.
    it "walks the body of a bare header below it from no prefix" do
      source = <<~RUBY
        class C
          class << self
            class D
              class A::E
                include M
              end
            end
          end
        end
      RUBY

      expect(includes(source)).to eq("A::E" => ["M"])
    end

    it "keeps the cref unnameable across an ordinary block and a hook's `def`" do
      block = "class C\n  class << self\n    foo { class D; include M; end }\n  end\nend\n"
      hook = <<~RUBY
        class C
          class << self
            class D
              def self.included(base)
                self::X.class_eval { include T }
              end
            end
          end
        end
      RUBY

      expect(includes(block)).to eq({})
      expect(includes(hook)).to eq({})
    end

    it "declines a `self::` receiver in it, and takes a constant one" do
      expect(includes("class C\n  class << self\n    self::X.class_eval { include T }\n  end\nend\n")).to eq({})
      expect(includes("class C\n  class << self\n    K.class_eval { include T }\n  end\nend\n")).to eq("K" => ["T"])
    end

    # The receiver's block has a `self` a name reaches again, though the cref around it has none.
    it "anchors a `self::` receiver on a constant receiver's block in it" do
      expect(includes("class C\n  class << self\n    K.class_eval { self::X.class_eval { include T } }\n  end\nend\n"))
        .to eq("K::X" => ["T"])
    end
  end

  describe "a constant write that creates a class" do
    it "files the block's mixins under the class the write names, not the class around it" do
      expect(tables("class Outer\n  Thing = Class.new { include Taggable }\nend\n"))
        .to eq(includes: { "Outer::Thing" => ["Taggable"] }, prepends: {},
               unpositioned: { "Outer::Thing" => { include: ["Taggable"] } })
    end

    it "reads a path write, both or-writes and every factory" do
      expect(includes("A::K = Class.new { include I }\n")).to eq("A::K" => ["I"])
      expect(includes("K ||= Class.new { include I }\n")).to eq("K" => ["I"])
      expect(includes("module Outer\n  A::K ||= Class.new { include I }\nend\n")).to eq("Outer::A::K" => ["I"])
      factories = "K = Struct.new(:a) { include T }\nL = Module.new { include U }\nM = Data.define(:a) { include V }\n"
      expect(includes(factories)).to eq("K" => ["T"], "L" => ["U"], "M" => ["V"])
    end

    it "anchors a `self::` write on the body it is written in, and on the block of a write around it" do
      expect(includes("self::K = Class.new { include T }\n")).to eq("K" => ["T"])
      expect(includes("class C\n  self::K = Class.new { include T }\nend\n")).to eq("C::K" => ["T"])
      expect(includes("class C\n  K = Class.new { self::X = Class.new { include T } }\nend\n"))
        .to eq("C::K::X" => ["T"])
    end

    # The factory call's arguments evaluate in the enclosing context.
    it "walks the arguments of the factory call in the context around the write" do
      expect(includes("class Outer\n  K = Class.new(X.class_eval { include T }) { include U }\nend\n"))
        .to eq("X" => ["T"], "Outer::K" => ["U"])
      expect(includes("class Outer\n  K = Class.new(include(A)) { include U }\nend\n"))
        .to eq("Outer" => ["A"], "Outer::K" => ["U"])
      expect(includes("class Outer\n  K = Class.new(Base.include(M)) { include U }\nend\n"))
        .to eq("Base" => ["M"], "Outer::K" => ["U"])
    end

    it "walks the arguments under the self and the cref around the write, nameable or not" do
      under_self = "Class.new { K = Class.new(self::X.class_eval { include T }) { } }\n"
      under_cref = "class C\n  class << self\n    ::K = Class.new((class D; include M; end; Base)) { }\n  end\nend\n"

      expect(includes(under_self)).to eq({})
      expect(includes(under_cref)).to eq({})
    end

    it "goes on with the body when the write has no block" do
      expect(includes("class Outer\n  K = Class.new\n  include M\nend\n")).to eq("Outer" => ["M"])
    end

    it "reads any other write as any other node" do
      expect(includes("class Outer\n  K = foo { include U }\nend\n")).to eq("Outer" => ["U"])
      expect(includes("class Outer\n  K = (include R; Class).new { include U }\nend\n")).to eq("Outer" => %w[U R])
    end

    # The block rebinds only `self`: `Module.nesting` stays lexical, so a header in it is the enclosing body's.
    it "files a header inside the block under the body around the write" do
      expect(includes("class C\n  K = Class.new { class Inner; include T; end }\nend\n")).to eq("C::Inner" => ["T"])
    end

    it "files nothing for a bare write under `class <<`, and a path write by its name" do
      under = ->(write) { includes("class C\n  class << self\n    #{write}\n  end\nend\n") }

      expect(under.call("K = Class.new { include T }")).to eq({})
      expect(under.call("::K = Class.new { include T }")).to eq("K" => ["T"])
      expect(under.call("::K = Class.new { class Inner; include T; end }")).to eq({})
    end
  end

  describe "a block that rebinds `self`" do
    it "files an eval-family block's mixins under the receiver, and under the enclosing class for `self` or none" do
      expect(includes("class Outer\n  Recv.class_eval { include M }\nend\n")).to eq("Recv" => ["M"])
      expect(includes("class Outer\n  class_eval { include T }\n  self.class_eval { include U }\nend\n"))
        .to eq("Outer" => %w[U T])
      expect(prepends("class C; end\nC.instance_eval { prepend T }\n")).to eq("C" => ["T"])
    end

    it "files nothing for the block of a class-creating call no write names, or of `define_method`" do
      expect(includes("class Outer\n  Class.new { include T }\n  define_method(:m) { include U }\nend\n")).to eq({})
    end

    it "files an ordinary block's mixins under the enclosing class" do
      expect(includes("class Outer\n  each { include U }\nend\n")).to eq("Outer" => ["U"])
    end

    it "walks the arguments of the call in the context around it" do
      expect(includes("class Outer\n  Recv.class_eval(include(A)) { include M }\nend\n"))
        .to eq("Outer" => ["A"], "Recv" => ["M"])
    end

    it "takes each block by its own receiver, and a constant receiver inside a block nothing names" do
      expect(includes("class Outer\n  A.class_eval { B.class_eval { include M }; include N }\nend\n"))
        .to eq("B" => ["M"], "A" => ["N"])
      expect(includes("class Outer\n  Class.new { B.class_eval { include M }; include N }\nend\n"))
        .to eq("B" => ["M"])
    end

    # The opaque-eval taint reads the receiver as written, and a `self::` path is no constant path to it: beside
    # the edge the walk files, the enclosing class is tainted as for a receiver nothing names.
    it "anchors a `self::` receiver on the enclosing class, and declines it where `self` names nothing" do
      expect(tables("class Outer\n  self::X.class_eval { include T }\nend\n"))
        .to eq(includes: { "Outer::X" => ["T"] }, prepends: {},
               unpositioned: { "Outer" => { include: unnamed, extend: wildcard }, "Outer::X" => { include: ["T"] } })
      expect(includes("self::X.class_eval { include T }\n")).to eq("X" => ["T"])
      expect(includes("class Outer\n  Class.new { self::X.class_eval { include M } }\nend\n")).to eq({})
    end

    # What is not the block of a call keeps the `self` the call is written under.
    it "keeps `self` unnameable for the arguments of a call, and for a hook's `def`, in a block nothing names" do
      expect(includes("Class.new { foo(self::X.class_eval { include T }) }\n")).to eq({})
      expect(includes("Class.new { def self.included(base); self::X.class_eval { include T }; end }\n")).to eq({})
    end

    # `Module.nesting` never rebinds: a header in the block is the enclosing body's.
    it "files a header inside the block under the body around the call" do
      expect(includes("class Outer\n  A.class_eval { class Inner; include M; end }\nend\n"))
        .to eq("Outer::Inner" => ["M"])
    end
  end

  describe "a hook's parameters" do
    def hook(body, header = "def self.included(base)") = "module Mo\n  #{header}\n    #{body}\n  end\nend\n"

    # `base` is the class that includes the module, which the walk cannot name.
    it "taints the module for a mixin on the parameter, and records none" do
      expect(tables(hook("base.include M")))
        .to eq(includes: {}, prepends: {}, unpositioned: { "Mo" => { include: unnamed } })
      expect(unpositioned(hook("base.send(:include, M)"))).to eq("Mo" => { include: unnamed })
      expect(unpositioned(hook("base.extend M"))).to eq("Mo" => { include: wildcard })
    end

    it "taints for the parameter's eval block and its computed `send`" do
      expect(unpositioned(hook("base.class_eval { foo }"))).to eq("Mo" => { include: unnamed, extend: wildcard })
      expect(unpositioned(hook("base.send(meth, M)"))).to eq("Mo" => { include: unnamed })
    end

    it "reads the parameters of `included`, `extended`, `prepended` and `inherited` alone" do
      %w[extended prepended inherited].each do |name|
        expect(unpositioned(hook("base.include M", "def self.#{name}(base)"))).to eq("Mo" => { include: unnamed })
      end
      expect(unpositioned(hook("base.include M", "def self.setup(base)"))).to eq({})
    end

    it "reads a hook written inside a hook by its own parameter, and no parameter after the `def`" do
      nested = hook("def self.extended(other)\n      other.include M\n    end")
      after = "module Mo\n  def self.included(base); end\n  base = Other\n  base.include M\nend\n"

      expect(unpositioned(nested)).to eq("Mo" => { include: unnamed })
      expect(unpositioned(after)).to eq({})
    end

    # Inside `class << self` this walk has no owner: the extend walk keeps the hook's instance-side taint there.
    it "taints nothing for a hook written where the walk names no class" do
      in_singleton = "module Mo\n  class << self\n    def included(base)\n      base.include M\n    end\n  end\nend\n"

      expect(unpositioned(in_singleton)).to eq({})
      expect(unpositioned("def self.included(base)\n  base.include M\nend\n")).to eq({})
    end
  end

  describe "a top-level `include`" do
    # `main.include` is `Object.include`, filed under its own key (#1697).
    it "files a receiverless `include` that is a statement of the program under the top-level key" do
      expect(tables("include M\n")).to eq(includes: { toplevel => ["M"] }, prepends: {}, unpositioned: {})
      expect(includes("include M\nclass C\n  include N\nend\n")).to eq(toplevel => ["M"], "C" => ["N"])
    end

    it "reads `self.include` and a `send` or `__send__` of the name as the same call, and not `public_send` (#2995)" do
      expect(includes("self.include M\n")).to eq(toplevel => ["M"])
      expect(includes("send(:include, M)\n__send__(:include, N)\n")).to eq(toplevel => %w[N M])
      expect(includes("public_send(:include, M)\n")).to eq({})
    end

    it "files nothing for a top-level `prepend` or `extend`" do
      expect(tables("prepend M\nextend N\n")).to eq(includes: {}, prepends: {}, unpositioned: {})
    end

    # A call under control flow or in a `def` may not run: its edge is in the set with no position (#3007).
    it "files a call under top-level control flow, in a top-level `def` or in a core iterator's block, unpositioned" do
      ["if x\n  include M\nend\n", "def setup\n  include M\nend\n", "[1].each do\n  include M\nend\n"].each do |source|
        expect(tables(source))
          .to include(includes: { toplevel => ["M"] }, unpositioned: { toplevel => { include: ["M"] } }), source
      end
    end

    it "files nothing for a call in a block whose `self` may not be `main`" do
      expect(tables("describe do\n  include M\nend\n")).to eq(includes: {}, prepends: {}, unpositioned: {})
    end

    it "taints the top-level key for an `include` of no constant" do
      expect(tables("include helper\n"))
        .to eq(includes: {}, prepends: {}, unpositioned: { toplevel => { include: unnamed } })
    end
  end

  # #1097 — inside a `*_eval` / `*_exec` block, `Module.nesting` stays LEXICAL while a mixin call binds to the
  # receiver. The examples of that group of `scope_indexer_spec.rb` that read the include table alone, moved as
  # they were; the ones that also read another table stay there.
  describe "eval-block dual context (#1097)" do
    it "declines a `self::` eval receiver inside a `class <<` body" do
      # Inside `class << self` self is the singleton — `self::X` raises NameError at
      # runtime unless the constant lives on that singleton — so the receiver declines
      # rather than filing the block under a class it never opened.
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        module M
          Y.class_eval do
            class << self
              self::X.class_eval { include T }
            end
          end
        end
      RUBY
      expect(table).not_to have_key("Y::X")
      expect(table).not_to have_key("M::X")
    end

    it "declines a `self::` eval receiver inside `class << <non-constant>`" do
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        class Y
          class << obj
            self::X.class_eval { include T }
          end
        end
      RUBY
      expect(table).not_to have_key("Y::X")
    end

    it "attributes `include` inside a `self::`-receiver eval block to the resolved owner" do
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        module M
          Y.class_eval do
            self::X.class_eval { include T }
          end
        end
      RUBY
      expect(table).to include("Y::X" => ["T"])
      expect(table).not_to have_key("M")
    end

    it "declines a `self::` eval receiver inside a `class` declaration under `class <<`" do
      # `class D` opens `#<Class:C>::D` — `self` inside is that unnameable class, so
      # `self::X` there cannot be spelled `C::D::X`.
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        class C
          class << self
            class D
              self::X.class_eval { include T }
            end
          end
        end
      RUBY
      expect(table).not_to have_key("X")
      expect(table).not_to have_key("C::D::X")
      expect(table).not_to have_key("D::X")
    end

    it "declines a `self::` eval receiver inside an opaque eval body" do
      # `obj.instance_eval`'s self is the receiver object — `self::X` resolves on its
      # singleton, a table nothing names — never `C::X`.
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        class C
          obj.instance_eval { self::X.class_eval { include T } }
        end
      RUBY
      expect(table).not_to have_key("C::X")
      expect(table).not_to have_key("X")
    end

    it "attributes `include` inside a meta-new block to the block's class" do
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        class C
          K = Class.new { include T }
        end
      RUBY
      expect(table).to include("C::K" => ["T"])
      expect(table).not_to have_key("C")
    end
  end

  # Issue #1123 — the instance-side prepend table: `{class => [module names, as written]}` in
  # instance-ancestor SEARCH order. It adds the prepend ORDER and KIND the include table cannot carry
  # (that one keeps every mixin in search order since #1173 — prepends ahead of includes — but is read
  # as a set by the arity / visibility / reflection consumers), and
  # `Scope#user_def_through_ancestors` searches it ahead of the class's own `def`s.
  describe ".build_discovered_prepends" do
    it "records an in-body `prepend` in both tables" do
      program = parse(<<~RUBY)
        module T; end
        class C
          prepend T
        end
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("C" => ["T"])
      expect(described_class.send(:build_discovered_includes, program)).to eq("C" => ["T"])
    end

    it "orders two statements nearest-first, and one statement's arguments in call order" do
      # `prepend A; prepend B` searches B first; `prepend A, B` makes A the nearer of the two. Since
      # #1173 the include table keeps the same search order — prepends sort ahead of includes there,
      # matching where Ruby puts them (before the class itself).
      program = parse(<<~RUBY)
        module A; end
        module B; end
        class Two
          prepend A
          prepend B
        end
        class One
          prepend A, B
        end
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("Two" => %w[B A], "One" => %w[A B])
      expect(described_class.send(:build_discovered_includes, program)).to eq("Two" => %w[B A], "One" => %w[A B])
    end

    it "orders `include` statements nearest-first, and one statement's arguments in written order" do
      # #1173 — `include A; include B` searches B first (Ruby's later-include-wins); `include A, B`
      # keeps `["A", "B"]` because one statement's argument list lands as a unit ahead of the earlier
      # statements'. The pre-#1173 call-order list answered `["A", "B"]` for both.
      program = parse(<<~RUBY)
        module A; end
        module B; end
        class Two
          include A
          include B
        end
        class One
          include A, B
        end
      RUBY
      expect(described_class.send(:build_discovered_includes, program)).to eq("Two" => %w[B A], "One" => %w[A B])
    end

    it "orders a mix of prepend and include the way the runtime ancestry does" do
      # `prepend` lands before the class itself, `include` after it, so both spellings and both
      # statement orders search the prepended module first.
      program = parse(<<~RUBY)
        module I; end
        module P; end
        class A
          include I
          prepend P
        end
        class B
          prepend P
          include I
        end
      RUBY
      expect(described_class.send(:build_discovered_includes, program)).to eq("A" => %w[P I], "B" => %w[P I])
    end

    it "records the `Recv.prepend(Mod)` call form under the receiver in both tables" do
      program = parse(<<~RUBY)
        module T; end
        class C; end
        C.prepend(T)
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("C" => ["T"])
      # The call form is the same ancestry edge as the declaration form, so the set-shaped include table
      # carries it too — otherwise the two spellings of one edge would answer differently for arity,
      # visibility and undefined-method suppression.
      expect(described_class.send(:build_discovered_includes, program)).to eq("C" => ["T"])
    end

    it "records the `Recv.include(Mod)` and `Recv.send(:include, Mod)` call forms in the include table only" do
      # Issue #1722 — the call form is the same ancestry edge as an in-body `include`, as `Recv.prepend(Mod)` is.
      program = parse(<<~RUBY)
        module T; end
        module U; end
        class C; end
        C.include(T)
        C.send(:include, U)
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to be_empty
      expect(described_class.send(:build_discovered_includes, program)).to eq("C" => %w[U T])
    end

    it "resolves an unqualified call-form receiver through the nesting the file declares" do
      program = parse(<<~RUBY)
        module Api
          module T; end
          class C; end
          C.prepend(T)
        end
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("Api::C" => ["T"])
    end

    it "declines a call-form receiver that names no static class" do
      program = parse(<<~RUBY)
        module T; end
        klass = Class.new
        klass.prepend(T)
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to be_empty
    end

    it "records a `prepend` written inside an eval block against the block's receiver" do
      program = parse(<<~RUBY)
        module T; end
        class C; end
        C.instance_eval { prepend T }
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("C" => ["T"])
    end
  end

  # What another file of `lib/` calls: the per-file merge and the cross-file fold of `scope_indexer.rb`. A second
  # name here is a new way into the module.
  it "exposes the entry alone, and no constant" do
    expect(described_class.singleton_methods(false)).to eq([:mixin_tables])
    expect(described_class.constants(false)).to eq([])
  end

  it "leaves none of its 17 functions on ScopeIndexer, public or private" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(17)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
  end

  # The calls the file spells on a module, by the module's name.
  def calls_on(receiver)
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/mixin_tables.rb")
    DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == receiver
    end
  end

  # The #3318 cut-off counts the functions a moved cluster calls back in what stays, and allows four. This one calls
  # two, recognisers the other walkers ask too: what a call mixes in, and the lexical `self`.
  it "calls two functions of the indexer, at two sites each" do
    expect(calls_on("ScopeIndexer"))
      .to eq(%i[mixin_call_view lexical_self_receiver? lexical_self_receiver? mixin_call_view])
  end

  # A call on a module that has left the file is no call back: these are the eight functions `MixinEffects` shows.
  it "asks the effects and taints through the eight functions that module shows" do
    asked = calls_on("MixinEffects")

    expect(asked.tally).to eq(program_statements: 2, hook_def_params: 1, meta_new_mixin_owner: 1, taint_opaque_eval: 1,
                              taint_computed_mixin_send: 1, mixin_effects: 1, taint_unrecorded_mixin: 1,
                              prepend_call_receiver: 1)
    expect(asked.uniq.sort).to eq(indexer::MixinEffects.singleton_methods(false).sort)
    expect(calls_on("ConstantTables")).to eq([:rebound_block_self])
  end

  describe "its callers" do
    let(:source) { "class C\n  include T\n  prepend P\n  def x; include U; end\nend\n" }

    def seeded_with(includes, prepends)
      empty.with_discovery(empty.discovery.with(discovered_includes: includes, discovered_prepends: prepends))
    end

    # The file under analysis is the later contribution for a class the seed holds: its names are nearer.
    it "is the three tables `ScopeIndexer.index` merges over the seed" do
      program = parse(source)
      alone = indexer.index(program, default_scope: empty)[program]
      seeded = indexer.index(program, default_scope: seeded_with({ "C" => ["Seed"] }, { "C" => ["SeedP"] }))[program]

      expect(alone.discovered_includes).to eq("C" => %w[P U T])
      expect(alone.discovered_prepends).to eq("C" => ["P"])
      expect(alone.discovery.unpositioned_mixins).to eq("C" => { include: ["U"] })
      expect(seeded.discovered_includes).to eq("C" => %w[P U T Seed])
      expect(seeded.discovered_prepends).to eq("C" => %w[P SeedP])
    end

    it "is the three tables the cross-file fold files" do
      Dir.mktmpdir do |dir|
        first = File.join(dir, "a.rb")
        second = File.join(dir, "b.rb")
        File.write(first, source)
        File.write(second, "class C\n  include V\nend\nC.prepend(Q)\n")
        index = indexer.discovered_def_index_for_paths([first, second])

        expect(index[:includes]).to eq("C" => %w[Q V P U T])
        expect(index[:prepends]).to eq("C" => %w[Q P])
        expect(index[:unpositioned_mixins]).to eq("C" => { include: %w[U Q] })
      end
    end
  end

  # The module calls two of the indexer's functions, which `scope_indexer.rb` defines: the file requires what else it
  # names, and until the indexer has loaded the entry answers only for a program that asks neither.
  def alone_probe
    <<~RUBY
      require "rigor/inference/scope_indexer/mixin_tables"
      tables = Rigor::Inference::ScopeIndexer::MixinTables
      run = lambda do |source|
        tables.mixin_tables(Prism.parse(source).value)
      rescue NameError => e
        [e.class.name, e.name]
      end
      answers = ["class C; X = 1; def m; 1; end; class << self; end; end\\nK = Class.new\\n", "foo", "class C; include M; end"]
      print [Rigor::Inference::ScopeIndexer.respond_to?(:index), defined?(Rigor::Inference::DeclarationWalk::Rules),
             defined?(Rigor::Inference::ScopeIndexer::MixinEffects), defined?(Rigor::Inference::ScopeIndexer::ConstantTables),
             defined?(Rigor::Inference::ScopeIndexer::MixinAccumulator), defined?(Rigor::Inference::ObjectMixins),
             defined?(Rigor::Source::ConstantPath), Prism::CallNode.method_defined?(:rigor_each_child),
             answers.map(&run)].inspect
    RUBY
  end

  it "loads without the indexer, with what it names, and answers only for a program with no call to read" do
    lib = File.join(DeclarationFactSources::REPO_ROOT, "lib")
    out, err, status = RubyRun.capture("-I", lib, "-e", alone_probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, "constant", "constant", "constant", "constant", "constant", "constant", true, ' \
                      '[{includes: {}, prepends: {}, unpositioned: {}}, ["NoMethodError", :mixin_call_view], ' \
                      '["NoMethodError", :mixin_call_view]]]')
  end
end
