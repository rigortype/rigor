# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/inference/scope_indexer"

# ADR-119 WD7 — `unpositioned_mixins` (`{owner => {include: [names], extend: [names]}}`) names the include / prepend /
# extend edges whose ORDER the mixin tables cannot vouch for, so a reader that depends on the order of a class's
# ancestors can decline where it is not known. The tables themselves are unchanged: every edge is still recorded, and
# this table only flags it. A mixin call the walk cannot record taints the whole owner side with `"*"`. When in doubt
# an edge is unpositioned, which sends the class to the answer the reader gave before it had the table.
RSpec.describe Rigor::Inference::ScopeIndexer::MixinAccumulator do
  def index_of(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.rb")
      File.write(path, source)
      described_index = Rigor::Inference::ScopeIndexer.discovered_project_index_for_paths([path])
      described_index.fetch(:def_index)
    end
  end

  def unpositioned(source)
    index_of(source).fetch(:unpositioned_mixins)
  end

  def wild(side = :include) = { side => ["*"] }

  context "when the edge's position is not a fact" do
    it "flags an include inside a def" do
      source = "class C\n  def other\n    include N\n  end\nend\n"

      expect(unpositioned(source)).to eq("C" => { include: ["N"] })
    end

    it "flags a prepend inside a def" do
      expect(unpositioned("class C\n  def setup\n    prepend M\n  end\nend\n")).to eq("C" => { include: ["M"] })
    end

    it "flags an edge under if, unless and a modifier", :aggregate_failures do
      { "if X\n    include M\n  end" => :include,
        "unless X\n    prepend M\n  end" => :include,
        "include M if X" => :include,
        "prepend M unless X" => :include,
        "extend M if X" => :extend }.each do |body, side|
        expect(unpositioned("class C\n  #{body}\nend\n")).to eq("C" => { side => ["M"] }), body
      end
    end

    it "flags an edge inside `included do` and `class_eval`", :aggregate_failures do
      expect(unpositioned("module Concern\n  included do\n    include M\n  end\nend\n"))
        .to eq("Concern" => { include: ["M"] })
      expect(unpositioned("class C\n  class_eval do\n    include M\n  end\nend\n")).to eq("C" => { include: ["M"] })
    end

    it "flags the receiver form, keyed by the receiver" do
      source = "class Base; end\nclass C\n  Base.prepend(M)\nend\n"

      expect(unpositioned(source)).to eq("Base" => { include: ["M"] })
    end

    # Issue #1722 — the receiver form of `include`, and its `send` spelling, record their edge as `prepend`'s does.
    it "flags the receiver form of include and of send(:include), keyed by the receiver", :aggregate_failures do
      expect(unpositioned("class Base; end\nBase.include(M)\n")).to eq("Base" => { include: ["M"] })
      expect(unpositioned("class Base; end\nBase.send(:include, M)\n")).to eq("Base" => { include: ["M"] })
      expect(unpositioned("class C\n  include A\n  C.include(B)\nend\n")).to eq("C" => { include: ["B"] })
    end

    it "flags an extend inside a method on the extend side only" do
      source = "class C\n  include A\n  def self.boot\n    extend M\n  end\nend\n"

      expect(unpositioned(source)).to eq("C" => { extend: ["M"] })
    end

    it "flags an include inside a method on the include side only, leaving a direct extend positioned" do
      source = "class C\n  extend E\n  def boot\n    include M\n  end\nend\n"

      expect(unpositioned(source)).to eq("C" => { include: ["M"] })
    end

    it "still records the edge in the ordinary tables" do
      index = index_of("class C\n  include M if X\nend\n")

      expect(index.fetch(:includes)).to eq("C" => ["M"])
    end
  end

  # #1592 — the extends walk dropped every block it did not recognise as a class body, so `[1].each { extend M }`
  # recorded nothing. A block runs on whatever object its call hands it, and may never run, so only a block that
  # PROVABLY runs at least once with the body's own `self` is read as the body's: `tap` / `then`, or an iterator
  # over a known non-empty literal, written as a statement of a class or module body. Its direct statements are
  # then positioned (the block runs where it is written; a repeated `extend` is idempotent). Every other block is
  # skipped, as before.
  context "when a singleton-side mixin is written in a block (#1592)" do
    {
      "[1].each { extend M }" => "extend in a non-empty Array each",
      "[1].each_with_index { extend M }" => "extend in each_with_index",
      "(1..3).each { extend M }" => "extend in a non-empty Range each",
      "(1...3).map { extend M }" => "extend in a non-empty exclusive Range map",
      "(1..5).step(2) { extend M }" => "extend in a Range step",
      "3.times { extend M }" => "extend in a positive times",
      "1.upto(3) { extend M }" => "extend in an ordered upto",
      "3.downto(1) { extend M }" => "extend in an ordered downto",
      "{ a: 1 }.each_pair { extend M }" => "extend in a non-empty Hash each_pair",
      "[1].map { extend M }" => "extend in map",
      "1.then { extend M }" => "extend in then on an Integer literal",
      "\"s\".tap { extend M }" => "extend in tap on a String literal",
      "[1].each { class << self; include M; end }" => "class << self; include in an iterator",
      "[1].each { class << self; prepend M; end }" => "class << self; prepend in an iterator"
    }.each do |body, label|
      it "records #{label} as positioned" do
        source = "class C\n  #{body}\nend\n"

        expect(index_of(source).fetch(:extends)).to eq("C" => ["M"]), body
        expect(unpositioned(source)).to eq({}), body
      end
    end

    it "lists the block extend when the class itself is not a direct statement" do
      source = "class C\n  [1].each { extend M }\nend if X\n"

      expect(unpositioned(source)).to eq("C" => { extend: ["M"] })
    end

    it "lists a conditional extend inside a provable block" do
      expect(unpositioned("class C\n  [1].each { extend M if X }\nend\n")).to eq("C" => { extend: ["M"] })
    end

    it "keeps the order of the block's statements relative to the body's" do
      source = "class C\n  extend A\n  [1].each { extend B }\n  extend D\nend\n"

      expect(index_of(source).fetch(:extends)).to eq("C" => %w[D B A])
      expect(unpositioned(source)).to eq({})
    end

    # The block's `self` is not the class (an instance, the class an `on_load` hook loaded, an `instance_exec`ed
    # DSL object), or the block may never yield. Nothing is recorded or listed, exactly the merge-base answer.
    {
      "@lock.synchronize { extend M }" => "a call on an instance variable",
      "def call = @lock.synchronize { extend M }" => "a block inside a method",
      "ActiveSupport.on_load(:active_record) { extend M }" => "an on_load hook",
      "helper { extend M }" => "a receiverless call",
      "included do\n    extend M\n  end" => "a concern's included do",
      "config.each { extend M }" => "a call on a non-literal receiver",
      "Registry.each { extend M }" => "a constant receiver, which may never yield",
      "Registry.tap { extend M }" => "a constant's tap, which the constant may override",
      "helper.then { extend M }" => "a then on a call, which may defer",
      "tap { extend M }" => "a receiverless tap, which may reach a class-level DSL method",
      "self.tap { extend M }" => "a tap on self, which the class may define as a singleton method",
      "LAZY.map { extend M }" => "a constant lazy enumerator",
      "[].each { extend M }" => "an empty Array literal",
      "[*list].each { extend M }" => "an Array literal with a splat",
      "{}.each { extend M }" => "an empty Hash literal",
      "0.times { extend M }" => "a zero times",
      "3.upto(1) { extend M }" => "a reversed upto",
      "(3..1).each { extend M }" => "an empty Range",
      "(1...1).each { extend M }" => "an empty exclusive Range",
      "(1..3).step(-1) { extend M }" => "a Range step that never advances",
      "[1].each_slice(2) { extend M }" => "a method outside the iterator list",
      "[1].each { [2].each { extend M } }" => "an iterator nested in another block",
      "[1].each { def z = [2].each { extend M } }" => "an iterator nested in a def"
    }.each do |body, label|
      it "skips an extend in #{label}" do
        source = "class C\n  #{body}\nend\n"

        expect(index_of(source).fetch(:extends)).to eq({}), body
        expect(unpositioned(source)).to eq({}), body
      end
    end

    it "skips an iterator that is not a statement of the body" do
      source = "class C\n  x = [1].each { extend M }\nend\n"

      expect(index_of(source).fetch(:extends)).to eq({})
    end

    it "leaves the instance side alone" do
      expect(unpositioned("class C\n  include A\n  [1].each { extend M if X }\nend\n")).to eq("C" => { extend: ["M"] })
    end

    # Issue #2994 — the argument names no module, so the singleton side also lists the unnamed marker.
    it "taints the extend side of an iterator extend whose argument cannot be named" do
      expect(unpositioned("class C\n  [1].each { |m| extend m }\nend\n")).to eq("C" => { extend: ["*", "?"] })
    end

    it "keeps a `Class.new` block on its own class, not the enclosing one" do
      source = "class C\n  K = Class.new { extend M }\n  Struct.new(:a) { extend N }\nend\n"

      expect(index_of(source).fetch(:extends)).to eq("C::K" => ["M"])
    end

    it "keeps a receiver on an iterator block off the enclosing class" do
      expect(unpositioned("class C\n  [1].each { obj.extend(M) }\nend\n")).to eq({})
    end
  end

  context "when a mixin call cannot be recorded" do
    # Every form leaves the direct `include A` recorded, so without the taint the class would read positioned.
    {
      "include helper" => :include,
      "include(*MODS)" => :include,
      "include A, helper" => :include,
      "include(Module.new { include B })" => :include,
      "extend helper" => :extend
    }.each do |statement, side|
      it "taints the #{side} side of the owner for `#{statement}`" do
        source = "class C\n  include A\n  extend E\n  #{statement}\nend\n"
        table = unpositioned(source).fetch("C")

        expect(table.fetch(side)).to include("*")
        expect(table.keys - [side]).to eq([]) unless statement.include?("A, helper")
        expect(index_of(source).fetch(:includes)).to include("C" => include("A"))
      end
    end

    # Issue #2995 — `self.include B` and a receiverless or `self.` `send(:include, B)` are the same call on the same
    # `self` as `include B`: each records its module under the class, positioned where the bare call would be, in the
    # include table and (for `prepend`) the prepend table, or in the extend table for `extend`. Ruby 4.0.5 puts `B` in
    # `C.ancestors` (or `C.singleton_class.ancestors`) at the same place for every spelling.
    {
      "self.include B" => [:includes, %w[B A]],
      "send(:include, B)" => [:includes, %w[B A]],
      "self.send(:include, B)" => [:includes, %w[B A]],
      "public_send(:include, B)" => [:includes, %w[B A]],
      "self.prepend B" => [:prepends, ["B"]],
      "__send__(:prepend, B)" => [:prepends, ["B"]],
      "self.extend B" => [:extends, %w[B E]],
      "send(:extend, B)" => [:extends, %w[B E]],
      "self.__send__(:extend, B)" => [:extends, %w[B E]]
    }.each do |statement, (table, recorded)|
      it "records `#{statement}` on the class, positioned" do
        source = "class C\n  include A\n  extend E\n  #{statement}\nend\n"

        expect(unpositioned(source)).to eq({})
        expect(index_of(source).fetch(table)).to eq("C" => recorded)
      end
    end

    it "records `self.include B` and `send(:prepend, B)` inside `class << self` on the extend side" do
      source = "class C\n  class << self\n    self.include B\n    send(:prepend, D)\n  end\nend\n"

      expect(unpositioned(source)).to eq({})
      expect(index_of(source).fetch(:extends)).to eq("C" => %w[D B])
    end

    # The call runs only when `setup` does, so the edge is recorded as a bare `include B` there is: in the set, with
    # no position.
    it "records `send(:include, B)` in a method body unpositioned" do
      source = "class C\n  include A\n  def self.setup = send(:include, B)\nend\n"

      expect(unpositioned(source)).to eq("C" => { include: ["B"] })
      expect(index_of(source).fetch(:includes)).to eq("C" => %w[B A])
    end

    it "keeps `Const.send(:extend, B)` a taint" do
      source = "class K; end\nclass C\n  K.send(:extend, B)\nend\n"

      expect(unpositioned(source)).to eq("K" => wild(:extend))
    end

    # Issue #2094 — the constant-receiver and `singleton_class` forms record their module on the extend side,
    # unpositioned, rather than tainting it.
    ["C.extend(B)", "singleton_class.include B", "C.singleton_class.prepend B"].each do |statement|
      it "records `#{statement}` on the extend side, unpositioned" do
        source = "class C\n  include A\n  extend E\n  #{statement}\nend\n"
        table = unpositioned(source).fetch("C")

        expect(table.fetch(:extend)).to eq(["B"])
        expect(index_of(source).fetch(:extends)).to include("C" => include("B", "E"))
      end
    end

    # Issue #2998 — a prepend on the class's own `singleton_class` runs where it is written, as `class << self;
    # prepend B` does, so a direct statement records it positioned, the `send` spelling included.
    ["self.singleton_class.prepend B", "singleton_class.send(:prepend, B)"].each do |statement|
      it "records `#{statement}` on the extend side, positioned" do
        source = "class C\n  include A\n  extend E\n  #{statement}\nend\n"

        expect(unpositioned(source)["C"]).to be_nil
        expect(index_of(source).fetch(:extends)).to include("C" => %w[B E])
      end
    end

    # Issue #3010 — `class << C` records its body's mixins on `C`'s extend side, positioned only as a direct statement
    # of a file that declares `C`.
    describe "a class << Const body" do
      it "records the body's include and prepend, positioned, after the file's own declaration" do
        source = "class C\n  extend E\nend\nclass << C\n  include A\n  prepend B\nend\n"

        expect(unpositioned(source)).to eq({})
        expect(index_of(source).fetch(:extends)).to include("C" => %w[B A E])
      end

      {
        "a file that does not declare the class" => "class << C\n  prepend B\nend\n",
        "a conditional" => "class C\nend\nclass << C\n  prepend B if $c\nend\n",
        "a method body" => "class C\nend\ndef s\n  class << C\n    prepend B\n  end\nend\n"
      }.each do |label, source|
        it "keeps the prepend in #{label} unpositioned" do
          expect(unpositioned(source)).to eq("C" => { extend: ["B"] })
        end
      end

      # Inside `module A`, `C` names `A::C` once that class exists; the file declares neither.
      it "records the prepend, unpositioned, on every class the constant may name" do
        source = "module A\n  class << C\n    prepend B\n  end\nend\n"

        expect(unpositioned(source)).to eq("A::C" => { extend: ["B"] }, "C" => { extend: ["B"] })
      end

      # The file declares the top-level `C` only; `A::C` from another file would be the one Ruby reaches.
      it "keeps the prepend unpositioned where a more-nested name is left beside the declared one" do
        source = "class C\nend\nmodule A\n  class << C\n    prepend B\n  end\nend\n"

        expect(unpositioned(source)).to eq("A::C" => { extend: ["B"] }, "C" => { extend: ["B"] })
      end

      # `class << C` inside `class C` is read as `class << self`, and `::C` names the top-level class (a regression row:
      # the rooted spelling already resolves to `C`).
      {
        "inside the class's own body" => ["class C\n  class << C\n    prepend B\n  end\nend\n", "C"],
        "with a rooted constant" => ["class C\nend\nclass << ::C\n  prepend B\nend\n", "C"]
      }.each do |label, (source, owner)|
        it "positions the prepend #{label}" do
          expect(unpositioned(source)).to eq({})
          expect(index_of(source).fetch(:extends)).to include(owner => ["B"])
        end
      end

      # A `prepend` in a `def` of the body runs on the class object's own ancestry, not on its singleton class.
      it "records no candidate edge for a prepend in a def of the body" do
        source = "module A\n  class << C\n    def x\n      prepend B\n    end\n  end\nend\n"

        expect(unpositioned(source)).not_to include("A::C")
      end

      # Ruby resolves `C` when the `class <<` runs, before the file declares `A::C`.
      it "keeps the prepend unpositioned on every candidate when the nested class is declared after it" do
        source = "class C\nend\nmodule A\n  class << C\n    prepend B\n  end\n  class C\n  end\nend\n"

        expect(unpositioned(source)).to eq("A::C" => { extend: ["B"] }, "C" => { extend: ["B"] })
      end

      # A class declared in a `class << self` body is the singleton class's constant, not `A::C`: Ruby resolves `C` to
      # the top-level class here.
      it "does not count a same-named class in an earlier class << self body as declared ahead" do
        source = "module A\n  class << self\n    class C\n    end\n  end\n  class << C\n    prepend B\n  end\n  " \
                 "class C\n  end\nend\n"

        expect(unpositioned(source)).to eq("A::C" => { extend: ["B"] }, "C" => { extend: ["B"] })
      end

      it "positions it on a nested class an earlier constant write declares" do
        source = "module A\n  C = Class.new\n  class << C\n    prepend B\n  end\nend\n"

        expect(unpositioned(source)).to eq({})
        expect(index_of(source).fetch(:extends)).to include("A::C" => ["B"])
      end

      it "positions it on the nested class the file declares" do
        source = "module A\n  class C\n  end\n  class << C\n    prepend B\n  end\nend\n"

        expect(unpositioned(source)).to eq({})
        expect(index_of(source).fetch(:extends)).to include("A::C" => ["B"])
      end

      # Issue #2994's marker: the module set is unknown on each class the constant may name.
      it "lists the unnamed marker for a prepend whose argument names no module", :aggregate_failures do
        expect(unpositioned("class C\nend\nclass << C\n  prepend(*MODS)\nend\n")).to eq("C" => { extend: ["*", "?"] })
        expect(unpositioned("module A\n  class << C\n    prepend(*MODS)\n  end\nend\n"))
          .to eq("A::C" => { extend: ["*", "?"] }, "C" => { extend: ["*", "?"] })
      end
    end

    it "keeps a conditional `singleton_class.prepend B` unpositioned" do
      source = "class C\n  singleton_class.prepend B if $c\nend\n"

      expect(unpositioned(source).fetch("C").fetch(:extend)).to eq(["B"])
    end

    # Issue #2994 — a singleton-side call whose module set is unknown lists the unnamed marker beside the wildcard.
    it "lists the unnamed marker on the extend side for a name it cannot spell", :aggregate_failures do
      expect(unpositioned("class C\n  extend M, h\nend\n")).to eq("C" => { extend: ["*", "?"] })
      expect(unpositioned("class C\n  singleton_class.include(*MODS)\nend\n")).to eq("C" => { extend: ["*", "?"] })
      literal = unpositioned("class C\n  singleton_class.include B\nend\n")
      expect(literal.fetch("C", {}).fetch(:extend, [])).not_to include("?")
    end

    it "taints, rather than records, `singleton_class.include B` inside `class << self`" do
      source = "class C\n  class << self\n    singleton_class.include B\n  end\nend\n"

      expect(unpositioned(source).fetch("C").fetch(:extend)).to include("*")
      expect(index_of(source).fetch(:extends).fetch("C", [])).not_to include("B")
    end

    # Issue #2991 — an `include` / `prepend` on the hook parameter itself also lists "?" on the instance side: the
    # includer gains a module no table records under it.
    it "taints the enclosing class for a call on a hook parameter", :aggregate_failures do
      both = { "Concern" => { include: ["*"], extend: ["*"] } }
      unnamed = { "Concern" => { include: ["*", "?"], extend: ["*"] } }
      {
        "def self.included(base)\n    base.include X\n  end" => unnamed,
        "def self.included(base)\n    base.extend X\n  end" => both,
        "def self.included(base)\n    base.prepend X\n  end" => unnamed,
        "def self.included(base)\n    base.singleton_class.include X\n  end" => both,
        # Issue #2994 — a splatted `base.extend` extends the includer, not `Concern`, so its singleton side stays "*".
        "def self.included(base)\n    base.extend(*XS)\n  end" => both,
        "def self.extended(base)\n    base.send(:include, X)\n  end" => unnamed,
        "def self.prepended(base)\n    base.include X\n  end" => unnamed,
        "def self.inherited(sub)\n    sub.include X\n  end" => unnamed,
        "def self.included(base = nil)\n    base.include X\n  end" => unnamed,
        "class << self\n    def included(base)\n      base.include X\n    end\n  end" => unnamed
      }.each do |hook, expected|
        expect(unpositioned("module Concern\n  #{hook}\nend\n")).to eq(expected), hook
      end
    end

    it "taints the enclosing class for an eval-family block on a hook parameter", :aggregate_failures do
      %w[class_eval module_eval class_exec module_exec instance_eval].each do |verb|
        source = "module Concern\n  def self.included(base)\n    base.#{verb} { include X }\n  end\nend\n"

        expect(unpositioned(source)).to eq("Concern" => { include: ["*", "?"], extend: ["*"] }), verb
      end
    end

    it "taints the enclosing class for an opaque eval block that mixes a module in, outside a hook" do
      source = "class C\n  include A\n  def m(mod)\n    mod.module_eval { include B }\n  end\nend\n"

      expect(unpositioned(source)).to eq("C" => { include: ["*", "?"], extend: ["*"] })
    end

    it "does not taint for an opaque eval block that mixes nothing in", :aggregate_failures do
      expect(unpositioned("class C\n  def m(o)\n    o.instance_eval { helper }\n  end\nend\n")).to eq({})
      expect(unpositioned("class C\n  def m(o)\n    o.class_eval { def x = 1 }\n  end\nend\n")).to eq({})
    end

    it "leaves an ordinary object receiver alone: Array#prepend, String#prepend and obj.extend", :aggregate_failures do
      [
        "def m(content) = content.prepend(other)",
        "def m(ids) = ids.prepend(*more)",
        "def m(path)\n    path.prepend(\"x\")\n  end",
        "def m(obj) = obj.extend(Decorator)",
        "def m(obj) = obj.singleton_class.include(Helper)",
        "def m(base) = base.include(X)"
      ].each do |body|
        expect(unpositioned("class C\n  include A\n  #{body}\nend\n")).to eq({}), body
      end
    end

    it "does not carry a hook's parameter names out of the hook" do
      source = "module M\n  def self.included(base) = nil\n  def other(base)\n    base.include X\n  end\nend\n"

      expect(unpositioned(source)).to eq({})
    end
  end

  context "when the edge is a direct statement of the body" do
    it "does not flag a direct include, prepend and extend" do
      source = <<~RUBY
        class C
          include A
          prepend B
          extend D
          include E, F
        end
        module Outer
          class Inner
            include G
          end
        end
      RUBY

      expect(unpositioned(source)).to eq({})
    end

    it "does not flag `extend self` or a bare module_function", :aggregate_failures do
      expect(unpositioned("module M\n  extend self\nend\n")).to eq({})
      expect(unpositioned("module M\n  module_function\n  def x = 1\nend\n")).to eq({})
    end

    it "does not flag `class << self; include M`" do
      expect(unpositioned("class C\n  class << self\n    include M\n  end\nend\n")).to eq({})
    end

    it "does not flag a direct edge of a compact-header class" do
      expect(unpositioned("class A::B\n  include M\nend\n")).to eq({})
    end
  end

  context "when the declaration is not itself a direct statement" do
    {
      "a modifier if" => "class C\n  include A\nend\nclass C\n  include B\nend if X\n",
      "an if body" => "class C\n  include A\nend\nif X\n  class C\n    include B\n  end\nend\n",
      "a block" => "class C\n  include A\nend\nActiveSupport.on_load(:x) do\n  class C\n    include B\n  end\nend\n",
      "a nested module in a conditional" =>
        "class C\n  include A\nend\nif X\n  module Outer\n    class C\n      include B\n    end\n  end\nend\n"
    }.each do |label, source|
      it "flags the edge written under #{label}" do
        table = unpositioned(source)

        expect(table.values.flat_map { |sides| sides.values.flatten }).to include("B")
        expect(table.values.flat_map { |sides| sides.values.flatten }).not_to include("A")
      end
    end

    it "flags a `class << self` include whose singleton class is conditional" do
      source = "class C\n  if X\n    class << self\n      include M\n    end\n  end\nend\n"

      expect(unpositioned(source)).to eq("C" => { extend: ["M"] })
    end

    it "keeps a declaration nested in a direct namespace direct" do
      expect(unpositioned("module Outer\n  module Mid\n    class C\n      include A\n    end\n  end\nend\n")).to eq({})
    end
  end

  context "when one edge is written both ways" do
    it "keeps the edge unpositioned within a file" do
      source = "class C\n  include M\n  include M if X\nend\n"

      expect(unpositioned(source)).to eq("C" => { include: ["M"] })
    end

    it "keeps the edge unpositioned across files, whichever file writes it directly" do
      Dir.mktmpdir do |dir|
        direct = File.join(dir, "a.rb")
        guarded = File.join(dir, "b.rb")
        File.write(direct, "class C\n  include M\nend\n")
        File.write(guarded, "class C\n  include M if X\n  extend N\nend\n")

        [[direct, guarded], [guarded, direct]].each do |paths|
          table = Rigor::Inference::ScopeIndexer.discovered_project_index_for_paths(paths)
                                                .fetch(:def_index).fetch(:unpositioned_mixins)
          expect(table).to eq("C" => { include: ["M"] })
        end
      end
    end
  end

  context "when nothing is noted" do
    it "answers one shared frozen table" do
      expect(described_class.new.unpositioned).to equal(described_class::EMPTY)
      expect(described_class::EMPTY).to be_frozen
    end
  end

  context "with a compact class header re-anchored to the top level" do
    it "rekeys the flagged edge with the class it belongs to, keeping both sides of a collision" do
      source = <<~RUBY
        class Outer; end
        class Outer::Leaf
          include M if X
        end
        module Wrap
          class Outer::Leaf
            extend N if X
          end
        end
      RUBY

      index = index_of(source)

      expect(index.fetch(:compact_header_renames)).to eq("Wrap::Outer::Leaf" => "Outer::Leaf")
      expect(index.fetch(:unpositioned_mixins)).to eq("Outer::Leaf" => { include: ["M"], extend: ["N"] })
    end
  end

  # The ADR-89 declaration signature decides whether a dependent is re-analysed after an edit. The order of a
  # class's mixins, and whether that order is known, are facts an ancestor-order reader consumes.
  describe "the declaration signature" do
    def signature(source)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "a.rb")
        File.write(path, source)
        Rigor::Inference::ScopeIndexer.discovered_project_index_incremental([path], seed_bundles: {})
                                      .fetch(:bundles).fetch(path).fetch(:declaration_signature)
      end
    end

    let(:base) { signature("class C\n  include A\n  include B\nend\n") }

    it "moves when an edit only reorders two includes" do
      expect(signature("class C\n  include B\n  include A\nend\n")).not_to eq(base)
    end

    it "moves when an edit only guards an include" do
      expect(signature("class C\n  include A\n  include B if X\nend\n")).not_to eq(base)
    end

    it "moves when an edit only reorders two prepends or two extends", :aggregate_failures do
      %w[prepend extend].each do |verb|
        before = signature("class C\n  #{verb} A\n  #{verb} B\nend\n")
        after = signature("class C\n  #{verb} B\n  #{verb} A\nend\n")
        expect(after).not_to eq(before), verb
      end
    end

    it "does not move for an unrelated whitespace edit" do
      expect(signature("class C\n\n  include A\n  include B\nend\n")).to eq(base)
    end
  end

  # Issue #3006 — a class-body `send` with a computed name and a further argument lists the unnamed marker on each
  # side the name may reach: the instance side for `include` / `prepend`, the singleton side for `extend`, and
  # inside `class << self` the singleton side for `include` / `prepend` alone.
  context "with a class-body computed-name `send` (#3006)" do
    it "lists the unnamed marker on the side each name may reach", :aggregate_failures do
      unnamed = ["*", "?"]
      { "k = :include\n  send(k, M)" => { include: unnamed },
        "k = :prepend\n  public_send(k, M)" => { include: unnamed },
        "k = :extend\n  __send__(k, M)" => { extend: unnamed },
        "send(name.to_sym, M)" => { include: unnamed, extend: unnamed },
        "class << self\n    k = :include\n    send(k, M)\n  end" => { extend: unnamed },
        "class << self\n    k = :extend\n    send(k, M)\n  end" => nil }.each do |body, sides|
        expected = sides ? { "C" => sides } : {}
        expect(unpositioned("class C\n  #{body}\nend\n")).to eq(expected), body
      end
    end

    it "lists it for a computed `send` in a second class of the file" do
      source = "class A\n  send(a.to_sym, M)\nend\nclass B\n  send(b.to_sym, M)\nend\n"
      expect(unpositioned(source).keys).to eq(%w[A B])
    end

    it "lists it on a hook's module for a computed `send` to the hook parameter, as for a literal one",
       :aggregate_failures do
      hook = ->(body) { "module Con\n  def self.included(base)\n    #{body}\n  end\nend\n" }
      expect(unpositioned(hook.call("meth = :include\n    base.send(meth, M)")))
        .to eq("Con" => { include: ["*", "?"], extend: ["*"] })
      expect(unpositioned(hook.call("meth = :extend\n    base.send(meth, M)")))
        .to eq("Con" => { include: ["*"], extend: ["*"] })
      expect(unpositioned(hook.call("meth = :attr_reader\n    base.send(meth, :x)"))).to eq({})
      singleton = "module Con\n  class << self\n    def included(base)\n      meth = :include\n      " \
                  "base.send(meth, M)\n    end\n  end\nend\n"
      expect(unpositioned(singleton)).to eq("Con" => { extend: ["*"], include: ["*", "?"] })
    end

    # The extends walk does not enter a block on a receiver it cannot vouch runs (#1592), so only the instance side
    # lists the marker; an unnamed instance-side module opens the class object too, through its `included` hook (#2994).
    it "lists it for a computed `send` in a block on a constant receiver" do
      expect(unpositioned("class C\n  KINDS.each { |m| send(m, M) }\nend\n")).to eq("C" => { include: ["*", "?"] })
    end

    it "does not list it for a literal non-mixin name, or a local bound in a nested `def`", :aggregate_failures do
      ["send(:attr_reader, :x)",
       "m = :attr_reader\n  send(m, :x)\n  def self.k\n    m = :include\n  end"].each do |body|
        expect(unpositioned("class C\n  #{body}\nend\n")).to eq({}), body
      end
    end
  end
end
