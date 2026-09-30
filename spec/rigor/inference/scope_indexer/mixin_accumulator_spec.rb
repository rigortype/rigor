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

  context "when a mixin call cannot be recorded" do
    # Every form leaves the direct `include A` recorded, so without the taint the class would read positioned.
    {
      "include helper" => :include,
      "include(*MODS)" => :include,
      "include A, helper" => :include,
      "send(:include, B)" => :include,
      "public_send(:include, B)" => :include,
      "__send__(:prepend, B)" => :include,
      "self.include B" => :include,
      "self.prepend B" => :include,
      "C.include(B)" => :include,
      "include(Module.new { include B })" => :include,
      "send(:extend, B)" => :extend,
      "self.extend B" => :extend,
      "extend helper" => :extend,
      "C.extend(B)" => :extend,
      "singleton_class.include B" => :extend,
      "self.singleton_class.prepend B" => :extend
    }.each do |statement, side|
      it "taints the #{side} side of the owner for `#{statement}`" do
        source = "class C\n  include A\n  extend E\n  #{statement}\nend\n"
        table = unpositioned(source).fetch("C")

        expect(table.fetch(side)).to include("*")
        expect(table.keys - [side]).to eq([]) unless statement.include?("A, helper")
        expect(index_of(source).fetch(:includes)).to include("C" => include("A"))
      end
    end

    it "taints the enclosing class for a call on a hook parameter", :aggregate_failures do
      both = { "Concern" => { include: ["*"], extend: ["*"] } }
      [
        "def self.included(base)\n    base.include X\n  end",
        "def self.included(base)\n    base.extend X\n  end",
        "def self.included(base)\n    base.prepend X\n  end",
        "def self.included(base)\n    base.singleton_class.include X\n  end",
        "def self.extended(base)\n    base.send(:include, X)\n  end",
        "def self.prepended(base)\n    base.include X\n  end",
        "def self.inherited(sub)\n    sub.include X\n  end",
        "def self.included(base = nil)\n    base.include X\n  end",
        "class << self\n    def included(base)\n      base.include X\n    end\n  end"
      ].each do |hook|
        expect(unpositioned("module Concern\n  #{hook}\nend\n")).to eq(both), hook
      end
    end

    it "taints the enclosing class for an eval-family block on a hook parameter", :aggregate_failures do
      %w[class_eval module_eval class_exec module_exec instance_eval].each do |verb|
        source = "module Concern\n  def self.included(base)\n    base.#{verb} { include X }\n  end\nend\n"

        expect(unpositioned(source)).to eq("Concern" => { include: ["*"], extend: ["*"] }), verb
      end
    end

    it "taints the enclosing class for an opaque eval block that mixes a module in, outside a hook" do
      source = "class C\n  include A\n  def m(mod)\n    mod.module_eval { include B }\n  end\nend\n"

      expect(unpositioned(source)).to eq("C" => { include: ["*"], extend: ["*"] })
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

    it "taints the receiver's class for a named-class call form anywhere" do
      expect(unpositioned("class Base; end\nBase.include(M)\n")).to eq("Base" => { include: ["*"] })
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
end
