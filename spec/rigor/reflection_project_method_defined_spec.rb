# frozen_string_literal: true

require "spec_helper"

# ADR-128 WD1 — `Reflection.project_method_defined`: the public facade over the two `Scope` ancestor walks. Each
# `source:` x `kind:` pair answers the walk it names, and `maybe` appears exactly where that walk's chain was cut
# at its budget before it found a definer.
RSpec.describe Rigor::Reflection, ".project_method_defined" do
  def scope_for(source)
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
  end

  def answer(scope, class_name, method_name, kind:, source:)
    described_class.project_method_defined(class_name, method_name, kind: kind, source: source, scope: scope)
  end

  # `Child` reaches `Base` and `Greeter`. Per the table that holds each method:
  #
  # - `plain`, `greet`, `self.build`, `self.shout`: a `def` (the def-node table, hence the discovery table too);
  # - `reader`, `defined`, and the singleton `config`: `attr_reader` / `define_method` only, no `Prism::DefNode`.
  let(:scope) do
    scope_for(<<~RUBY)
      module Greeter
        def greet = 1
      end

      module Shouter
        def shout = 1
      end

      class Base
        def plain = 1
        attr_reader :reader
        define_method(:defined) { 1 }
        def self.build = 1
        class << self
          attr_reader :config
        end
      end

      class Child < Base
        include Greeter
        extend Shouter
      end
    RUBY
  end

  describe "an instance definer" do
    it "answers yes from the def walk for a def on the class, an ancestor and an included module" do
      expect(answer(scope, "Child", :plain, kind: :instance, source: :def)).to eq(Rigor::Trinary.yes)
      expect(answer(scope, "Child", :greet, kind: :instance, source: :def)).to eq(Rigor::Trinary.yes)
    end

    it "answers no from the def walk for an absent name" do
      expect(answer(scope, "Child", :absent, kind: :instance, source: :def)).to eq(Rigor::Trinary.no)
    end

    it "answers yes from the discovery walk for a def, an attr_reader and a define_method" do
      %i[plain greet reader defined].each do |name|
        expect(answer(scope, "Child", name, kind: :instance, source: :discovered)).to eq(Rigor::Trinary.yes)
      end
    end

    it "answers no from the discovery walk for an absent name" do
      expect(answer(scope, "Child", :absent, kind: :instance, source: :discovered)).to eq(Rigor::Trinary.no)
    end

    it "does not count attr_reader or define_method as a def, but counts them as discovered" do
      %i[reader defined].each do |name|
        expect(answer(scope, "Child", name, kind: :instance, source: :def)).to eq(Rigor::Trinary.no)
        expect(answer(scope, "Child", name, kind: :instance, source: :either)).to eq(Rigor::Trinary.yes)
      end
    end

    it "answers either: yes from the def half, yes from the discovery half alone, and no from neither" do
      expect(answer(scope, "Child", :plain, kind: :instance, source: :either)).to eq(Rigor::Trinary.yes)
      expect(answer(scope, "Child", :reader, kind: :instance, source: :either)).to eq(Rigor::Trinary.yes)
      expect(answer(scope, "Child", :absent, kind: :instance, source: :either)).to eq(Rigor::Trinary.no)
    end
  end

  describe "a singleton definer" do
    it "answers yes from the def walk for a def self. on an ancestor and for an extended module's def" do
      expect(answer(scope, "Child", :build, kind: :singleton, source: :def)).to eq(Rigor::Trinary.yes)
      expect(answer(scope, "Child", :shout, kind: :singleton, source: :def)).to eq(Rigor::Trinary.yes)
    end

    it "answers no from the def walk for an absent name and for an attr_reader on the singleton" do
      expect(answer(scope, "Child", :absent, kind: :singleton, source: :def)).to eq(Rigor::Trinary.no)
      expect(answer(scope, "Child", :config, kind: :singleton, source: :def)).to eq(Rigor::Trinary.no)
    end

    it "answers from the discovery walk for the singleton table" do
      expect(answer(scope, "Child", :build, kind: :singleton, source: :discovered)).to eq(Rigor::Trinary.yes)
      expect(answer(scope, "Child", :config, kind: :singleton, source: :discovered)).to eq(Rigor::Trinary.yes)
      expect(answer(scope, "Child", :absent, kind: :singleton, source: :discovered)).to eq(Rigor::Trinary.no)
    end

    it "answers either: the discovery half alone carries the singleton attr_reader" do
      expect(answer(scope, "Child", :config, kind: :singleton, source: :either)).to eq(Rigor::Trinary.yes)
      expect(answer(scope, "Child", :absent, kind: :singleton, source: :either)).to eq(Rigor::Trinary.no)
    end

    it "keeps the two kinds apart" do
      expect(answer(scope, "Child", :build, kind: :instance, source: :either)).to eq(Rigor::Trinary.no)
      expect(answer(scope, "Child", :plain, kind: :singleton, source: :either)).to eq(Rigor::Trinary.no)
    end
  end

  # A chain past `ResolutionChain::LIMIT` project entries is cut, provided something follows the cut (the
  # superclass `Base`). `include M1 .. include Mn` puts `Mn` first, so the first modules (`M1`) are the ones past
  # the cut (every module defines a method, as an empty module is not an entry): `deep` there cannot be ruled in
  # or out, while `near` on the last module is inside it.
  describe "a chain cut at its budget" do
    let(:limit) { Rigor::Scope::ResolutionChain::LIMIT }
    let(:count) { limit + 5 }
    let(:cut_scope) do
      scope_for(
        modules_source({ 1 => "def deep = 1\nattr_reader :deep_reader", count => "def near = 1\ninclude Comparable" })
      )
    end

    # `Cut < Base` mixes in `M1 .. Mn`: by `include`, or (`extend: true`) through one `extend Ext` of a module that
    # includes them, since `extend` folds a module's own `def`s into the extender and only the modules IT includes
    # are entries of their own on the singleton chain.
    def modules_source(body_by_index, extend: false)
      modules = (1..count).map do |i|
        "module M#{i}\n  def m#{i} = #{i}\n#{body_by_index.fetch(i, '')}\nend"
      end
      includes = (1..count).map { |i| "  include M#{i}" }.join("\n")
      host = if extend
               "module Ext\n#{includes}\nend\n" \
                 "class Cut < Base\n  extend Ext\n  class << self\n    attr_reader :own_config\n  end\nend"
             else
               "class Cut < Base\n#{includes}\nend"
             end
      "#{modules.join("\n")}\nclass Base; end\n#{host}\n"
    end

    it "builds a truncated chain (the premise)" do
      chain = Rigor::Scope::ResolutionChain.for(cut_scope, "Cut", :instance, :methods)
      expect(chain).to be_truncated
    end

    it "answers maybe from the def walk for a name past the cut, and yes for one inside it" do
      expect(answer(cut_scope, "Cut", :deep, kind: :instance, source: :def)).to eq(Rigor::Trinary.maybe)
      expect(answer(cut_scope, "Cut", :absent, kind: :instance, source: :def)).to eq(Rigor::Trinary.maybe)
      expect(answer(cut_scope, "Cut", :near, kind: :instance, source: :def)).to eq(Rigor::Trinary.yes)
    end

    it "answers maybe from the discovery walk for a name past the cut, and yes for one inside it" do
      expect(answer(cut_scope, "Cut", :deep_reader, kind: :instance, source: :discovered))
        .to eq(Rigor::Trinary.maybe)
      expect(answer(cut_scope, "Cut", :absent, kind: :instance, source: :discovered)).to eq(Rigor::Trinary.maybe)
      expect(answer(cut_scope, "Cut", :near, kind: :instance, source: :discovered)).to eq(Rigor::Trinary.yes)
    end

    it "answers either: maybe where both halves are cut, and yes where one half finds it" do
      expect(answer(cut_scope, "Cut", :deep, kind: :instance, source: :either)).to eq(Rigor::Trinary.maybe)
      expect(answer(cut_scope, "Cut", :near, kind: :instance, source: :either)).to eq(Rigor::Trinary.yes)
    end

    it "lets a discovered hit inside the cut beat the def half's maybe" do
      near_attr = scope_for(modules_source({ count => "attr_reader :near_reader" }))

      expect(answer(near_attr, "Cut", :near_reader, kind: :instance, source: :def)).to eq(Rigor::Trinary.maybe)
      expect(answer(near_attr, "Cut", :near_reader, kind: :instance, source: :either)).to eq(Rigor::Trinary.yes)
    end

    it "answers maybe on the singleton chain too, from each walk" do
      extended = scope_for(modules_source({ 1 => "def deep = 1", count => "def near = 1" }, extend: true))

      expect(answer(extended, "Cut", :deep, kind: :singleton, source: :def)).to eq(Rigor::Trinary.maybe)
      expect(answer(extended, "Cut", :deep, kind: :singleton, source: :discovered)).to eq(Rigor::Trinary.maybe)
      expect(answer(extended, "Cut", :near, kind: :singleton, source: :def)).to eq(Rigor::Trinary.yes)
      expect(answer(extended, "Cut", :near, kind: :singleton, source: :discovered)).to eq(Rigor::Trinary.yes)
    end

    it "reads the class object's own singleton table inside a cut singleton chain" do
      extended = scope_for(modules_source({ 1 => "def deep = 1" }, extend: true))

      expect(answer(extended, "Cut", :own_config, kind: :singleton, source: :def)).to eq(Rigor::Trinary.maybe)
      expect(answer(extended, "Cut", :own_config, kind: :singleton, source: :discovered)).to eq(Rigor::Trinary.yes)
      expect(answer(extended, "Cut", :own_config, kind: :singleton, source: :either)).to eq(Rigor::Trinary.yes)
    end

    it "leaves both Scope walks answering what they answered before the facade" do
      expect(cut_scope.user_def_through_ancestors("Cut", :deep)).to eq([nil, nil])
      expect(cut_scope.discovered_method_through_ancestors?("Cut", :deep, :instance)).to be(true)
      expect(cut_scope.discovered_method_through_ancestors?("Cut", :absent, :instance)).to be(true)
    end
  end

  describe "arguments" do
    it "answers no for a nil class name" do
      expect(answer(scope, nil, :plain, kind: :instance, source: :either)).to eq(Rigor::Trinary.no)
    end

    it "answers no for a class the project does not declare" do
      expect(answer(scope, "Nowhere", :plain, kind: :instance, source: :either)).to eq(Rigor::Trinary.no)
    end

    it "rejects an unknown kind or source" do
      expect { answer(scope, "Child", :plain, kind: :class, source: :def) }.to raise_error(ArgumentError, /kind/)
      expect { answer(scope, "Child", :plain, kind: :instance, source: :any) }.to raise_error(ArgumentError, /source/)
    end
  end
end
