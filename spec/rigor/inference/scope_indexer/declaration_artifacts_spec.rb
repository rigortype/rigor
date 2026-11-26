# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "rigor/inference/scope_indexer"
require "rigor/inference/pre_eval_constants"

# ADR-116 WD9 (#3400) — `ScopeIndexer::DeclarationArtifacts` builds the declaration artifacts of one file. The
# examples hand `build_declaration_artifacts` a parsed snippet, and the names a project declares where the
# re-anchoring is asked, and read the two tables back: no index is built and no body evaluated, apart from the two
# examples that pin the callers. The examples that read the same tables through `ScopeIndexer.index` and through a
# run stay where they are, since they also read what the scope makes of them.
RSpec.describe Rigor::Inference::ScopeIndexer::DeclarationArtifacts do
  let(:indexer) { Rigor::Inference::ScopeIndexer }
  let(:empty) { Rigor::Scope.empty }

  def parse(source)
    Prism.parse(source).value
  end

  def singleton(name) = Rigor::Type::Combinator.singleton_of(name)

  def artifacts(source, declared_names = nil)
    described_class.build_declaration_artifacts(parse(source), declared_names)
  end

  # The names of the classes a snippet declares, in the order the table holds them.
  def names(source, declared_names = nil) = artifacts(source, declared_names).last.keys

  # The identity table of a snippet, each path node as its text with the class it is typed as.
  def typed(source, declared_names = nil)
    artifacts(source, declared_names).first.map { |node, type| [node.slice, type.describe] }
  end

  describe "the two tables" do
    it "answers the identity table of the headers' path nodes and the classes by qualified name, both frozen" do
      root = parse("module Foo; class Bar; end; end\nclass Baz < Base; end\n")
      table, discovered = described_class.build_declaration_artifacts(root)
      foo = root.statements.body.first

      expect(discovered).to eq("Foo" => singleton("Foo"), "Foo::Bar" => singleton("Foo::Bar"),
                               "Baz" => singleton("Baz"))
      expect(table.to_a).to eq([[foo.constant_path, singleton("Foo")],
                                [foo.body.body.first.constant_path, singleton("Foo::Bar")],
                                [root.statements.body.last.constant_path, singleton("Baz")]])
      expect([table, discovered]).to all(be_frozen)
    end

    it "keys the identity table by the node itself, not by a node that reads the same" do
      root = parse("class A; end\n")
      table, = described_class.build_declaration_artifacts(root)

      expect(table).to be_compare_by_identity
      expect(table[root.statements.body.first.constant_path]).to eq(singleton("A"))
      expect(table[parse("class A; end\n").statements.body.first.constant_path]).to be_nil
    end

    it "is two empty tables for a program that declares nothing, and for no node" do
      expect(artifacts("x = 1\nfoo { bar }\n")).to eq([{}, {}])
      expect(described_class.build_declaration_artifacts(nil)).to eq([{}, {}])
      expect(described_class.build_declaration_artifacts(nil)).to all(be_frozen)
    end

    it "types the outermost path node of a compact header alone, as the class of the whole path" do
      expect(typed("class A::B::C; end\n")).to eq([["A::B::C", "singleton(A::B::C)"]])
    end

    it "types each header of a reopened class, and registers the name once" do
      expect(typed("class A; end\nclass A; end\n")).to eq([["A", "singleton(A)"], ["A", "singleton(A)"]])
      expect(names("class A; end\nclass A; end\n")).to eq(%w[A])
    end
  end

  describe "a class or module header" do
    it "registers a nested declaration under the header around it, and starts again at a rooted one" do
      expect(names("module A; class B; end; class ::D; module E; end; end; end\n")).to eq(%w[A A::B D D::E])
    end

    it "finds a declaration wherever it is written: a value, an argument, a branch, a block, a def body" do
      source = <<~RUBY
        x = (class InValue; self; end)
        foo(class InArg; self; end)
        if c then class InBranch; end end
        [1].each { class InBlock; end }
        def m; class InDef; end; end
      RUBY

      expect(names(source)).to eq(%w[InValue InArg InBranch InBlock InDef])
    end

    it "anchors a `self::` header on the body it is written in" do
      expect(typed("module M; module self::O; end; end\n")).to eq([["M", "singleton(M)"], ["self::O", "singleton(M::O)"]])
    end

    it "hands its body no rebound self: a `self::` header inside it is the header's own" do
      expect(names("class C; K = Class.new { class Inner; class self::S; end; end }; end\n"))
        .to eq(%w[C C::K C::Inner C::Inner::S])
    end

    it "is walked through its body alone: the superclass is not walked" do
      expect(names("class C < (class D; self; end); end\n")).to eq(%w[C])
    end

    # Prism recovers `class foo` as a header whose path is a call: it names no constant, so it is any node, and
    # what it holds is walked under the prefix around it.
    it "is not registered when it names no constant" do
      root = parse("class foo; class A; end; end\n")

      expect(root.statements.body.first.constant_path).to be_a(Prism::CallNode)
      expect(described_class.build_declaration_artifacts(root).last.keys).to eq(%w[A])
    end

    it "starts from the prefix and the rebound self the walk is handed" do
      discovered = {}
      described_class.send(:record_declarations, parse("class X; end\nclass self::Y; end\n"), ["Outer"],
                           {}.compare_by_identity, discovered)
      rebound = {}
      described_class.send(:record_declarations, parse("class X; end\nclass self::Y; end\n"), ["Outer"],
                           {}.compare_by_identity, rebound, described_class::EMPTY_RENAMES, ["Re"])

      expect(discovered.keys).to eq(%w[Outer::X Outer::Y])
      expect(rebound.keys).to eq(%w[Outer::X Re::Y])
    end
  end

  # Issue #528 — what the entry hands `ScopeIndexer.synthesize_namespace_prefixes`.
  describe "the namespaces a compact name implies" do
    it "adds every proper prefix the file does not declare, after the declared names" do
      expect(names("class Api::V1::Users; end\n")).to eq(%w[Api::V1::Users Api Api::V1])
      expect(names("module Api; end\nclass Api::V1::Users; end\n")).to eq(%w[Api Api::V1::Users Api::V1])
    end

    it "types no node for a namespace it adds" do
      expect(typed("class Api::V1::Users; end\n")).to eq([["Api::V1::Users", "singleton(Api::V1::Users)"]])
    end
  end

  describe "a `class <<` body" do
    it "declines a bare header and what is bare beneath it, and starts again at a header that names a path" do
      source = <<~RUBY
        class C
          class << self
            class Hidden; class Deep; end; class Other::Leaf; end; end
            class ::Rooted; class In; end; end
          end
        end
      RUBY

      expect(typed(source)).to eq([["C", "singleton(C)"], ["Other::Leaf", "singleton(Other::Leaf)"],
                                   ["::Rooted", "singleton(Rooted)"], ["In", "singleton(Rooted::In)"]])
      expect(names(source)).to eq(%w[C Other::Leaf Rooted Rooted::In Other])
    end

    it "walks the expression in the enclosing context, under the self and the cref around it" do
      expect(names("class C; class << (class D; self; end); end; end\n")).to eq(%w[C C::D])
      expect(names("class C; K = Class.new { class << (class self::E; self; end); end }; end\n"))
        .to eq(%w[C C::K C::K::E])
      expect(names("class C; class << self; class << (class D; self; end); end; end; end\n")).to eq(%w[C])
    end

    it "declines a `self::` header: `self` is the singleton class there" do
      expect(names("class C; class << self; class self::S; end; end; end\n")).to eq(%w[C])
    end

    it "is a context the walk can be handed: a bare or `self::` header declines, a path header does not" do
      discovered = {}
      source = "class Y; end\nclass ::Z; end\nclass self::W; end\nclass A::B; end\n"
      described_class.send(:record_declarations, parse(source), ["Outer"], {}.compare_by_identity, discovered,
                           described_class::EMPTY_RENAMES, nil, singleton_cref: true)

      expect(discovered.keys).to eq(%w[Z Outer::A::B])
    end
  end

  describe "a constant write that creates a class" do
    it "registers the constant for each of the four forms and a wrapped factory, and types no node for it" do
      source = "class C; K = Class.new; D = Data.define(:a); S = Struct.new(:x); M = Module.new; " \
               "W = Class.new(Struct.new(:a)); end\n"

      expect(names(source)).to eq(%w[C C::K C::D C::S C::M C::W])
      expect(typed(source)).to eq([["C", "singleton(C)"]])
      expect(artifacts("K = Struct.new(:a)\n")).to eq([{}, { "K" => singleton("K") }])
    end

    it "registers a path write under the name it writes, and an or-write as a plain one" do
      expect(names("class C; ::K = Class.new; A::B = Struct.new(:x); self::S = Class.new; end\n"))
        .to eq(%w[C K C::A::B C::S C::A])
      expect(names("class C; K ||= Class.new; A::B ||= Struct.new(:x); end\n")).to eq(%w[C C::K C::A::B C::A])
    end

    it "walks the block with `self` rebound to the class the write names, and the cref left lexical" do
      expect(typed("class C; K = Class.new { class Inner; end; class self::Own; end }; end\n"))
        .to eq([["C", "singleton(C)"], ["Inner", "singleton(C::Inner)"], ["self::Own", "singleton(C::K::Own)"]])
    end

    it "walks the receiver and the arguments of the call under the enclosing self" do
      expect(names("class C; K = Class.new(class self::Y; self; end) { class self::Z; end }; end\n"))
        .to eq(%w[C C::K C::Y C::K::Z])
      expect(names("class C; X.class_eval { K = Class.new(class self::Y; self; end) }; end\n"))
        .to eq(%w[C C::K X::Y X])
    end

    it "anchors a `self::` write on the rebound self around it" do
      expect(names("class C; X.class_eval { self::K = Class.new }; end\n")).to eq(%w[C X::K X])
    end

    it "takes a block argument for no block" do
      expect(names("class C; K = Class.new(&blk); S = Struct.new(:a, &blk); end\n")).to eq(%w[C C::K C::S])
    end

    it "under `class <<`, keeps the cref unnameable for what the call and its block hold" do
      expect(names("class C; class << self; ::J = Class.new(class D; self; end) { class E; end }; end; end\n"))
        .to eq(%w[C J])
    end

    it "under `class <<`, declines a bare write with what its block anchors on `self`, and takes a path write" do
      source = "class C; class << self; K = Class.new { class self::In; end }; " \
               "::J = Class.new { class self::In; end }; self::L = Class.new; end; end\n"

      expect(names(source)).to eq(%w[C J J::In])
    end

    it "under `class <<`, takes a `self::` write in a path write's block, and no `self::` header below a bare one" do
      expect(names("class C; class << self; ::J = Class.new { self::L = Class.new }; end; end\n")).to eq(%w[C J J::L])
      expect(names("class C; class << self; ::J = Class.new { class D; class self::S; end; end }; end; end\n"))
        .to eq(%w[C J])
    end

    it "registers nothing for a `self::` write on a self nothing names, and walks its block" do
      expect(names("class C; foo.class_eval { self::K = Class.new { class self::In; end; class Bare; end } }; end\n"))
        .to eq(%w[C C::Bare])
    end

    it "is any other write when its value creates no class, or its target names nothing" do
      source = "class C; K = foo; L = Class.new.new; N = 1; O = Object.new { class InBlock; end }; " \
               "A, B = Class.new, Class.new; P &&= Class.new; foo::Q = Class.new { class self::Own; end }; end\n"

      expect(names(source)).to eq(%w[C C::InBlock C::Own])
    end
  end

  describe "an eval-family block" do
    it "anchors a `self::` header on the receiver and leaves a bare one lexical, `instance_eval` included" do
      expect(names("class X; end\nmodule M; X.class_eval { class self::Inner; end; class Bare; end }; end\n"))
        .to eq(%w[X M X::Inner M::Bare])
      expect(names("module M; Foo.instance_eval { class self::Inner; end }; end\n")).to eq(%w[M Foo::Inner Foo])
    end

    it "anchors on the enclosing body for a receiverless call, and on nothing for a receiver that names no class" do
      expect(names("class C; class_eval { class self::A; end }; end\n")).to eq(%w[C C::A])
      expect(names("class C; foo.class_eval { class self::A; end; class B; end }; end\n")).to eq(%w[C C::B])
    end

    it "reads a `self::` receiver under the enclosing self, and declines it where that self names nothing" do
      expect(names("class C; self::K.class_eval { class self::A; end }; end\n")).to eq(%w[C C::K::A C::K])
      expect(names("class C; class << self; self::K.class_eval { class self::A; end }; end; end\n")).to eq(%w[C])
    end

    it "anchors a receiverless eval inside a class-creating block on the class the write names" do
      expect(names("class C; K = Class.new { class_eval { class self::A; end } }; end\n")).to eq(%w[C C::K C::K::A])
    end

    it "under `class <<`, anchors a `self::` header on nothing, declines a bare one and still takes a rooted one" do
      source = "class C; class << self; class_eval { class self::A; end; class B; end; class ::R; end }; end; end\n"

      expect(names(source)).to eq(%w[C R])
    end

    it "walks the receiver and the arguments of the call under the self and the cref around it" do
      expect(names("class C; X.class_eval(class self::P; self; end) { class self::Q; end }; end\n"))
        .to eq(%w[C C::P X::Q X])
      expect(names("class C; K = Class.new { X.class_eval(class self::P; self; end) { 1 } }; end\n"))
        .to eq(%w[C C::K C::K::P])
      expect(names("class C; class << self; X.class_eval(class D; self; end) { class self::F; end }; end; end\n"))
        .to eq(%w[C X::F X])
    end

    it "is any other call under another name or without a block: an ordinary block rebinds nothing" do
      expect(names("class C; [1].each { class self::A; end; class B; end }; X.class_eval(class D; end); end\n"))
        .to eq(%w[C C::A C::B C::D])
    end
  end

  # Issue #722 — the file's share of the fold's re-anchoring, against the names the project declares.
  describe "the compact-header re-anchoring" do
    let(:source) { "module Wrap; class Outer::Inner; end; end\n" }

    it "re-anchors a compact header the project's names settle outside the body, in both tables" do
      expect(names(source, Set["Outer", "Wrap"])).to eq(%w[Wrap Outer::Inner Outer])
      expect(typed(source, Set["Outer", "Wrap"]))
        .to eq([["Wrap", "singleton(Wrap)"], ["Outer::Inner", "singleton(Outer::Inner)"]])
    end

    it "keeps the lexical name when the project declares it too, or declares neither" do
      expect(names(source, Set["Outer", "Wrap", "Wrap::Outer"])).to eq(%w[Wrap Wrap::Outer::Inner Wrap::Outer])
      expect(names(source, Set["Wrap"])).to eq(%w[Wrap Wrap::Outer::Inner Wrap::Outer])
    end

    it "re-anchors nothing with no project names to ask" do
      expect(names(source)).to eq(%w[Wrap Wrap::Outer::Inner Wrap::Outer])
      expect(names(source, Set[])).to eq(%w[Wrap Wrap::Outer::Inner Wrap::Outer])
    end

    it "walks the body of a re-anchored header under its new name" do
      nested = "module Wrap; class Outer::Inner; class Leaf; end; class self::Own; end; end; end\n"

      expect(names(nested,
                   Set["Outer", "Wrap"])).to eq(%w[Wrap Outer::Inner Outer::Inner::Leaf Outer::Inner::Own Outer])
    end

    it "registers a class-creating write in the body of a re-anchored header under the new name" do
      expect(names("module Wrap; class Outer::Inner; K = Class.new; end; end\n", Set["Outer", "Wrap"]))
        .to eq(%w[Wrap Outer::Inner Outer::Inner::K Outer])
    end

    # D55: a path header below a header that declines is written from the top, and still re-anchored.
    it "re-anchors a path header below a header that declines" do
      nested = "module Wrap; class Outer::Inner; end; " \
               "class << self; class Hidden; class Wrap::Outer::Inner::Leaf; end; end; end; end\n"

      expect(names(nested, Set["Outer", "Wrap"])).to eq(%w[Wrap Outer::Inner Outer::Inner::Leaf Outer])
      expect(names(nested)).to eq(%w[Wrap Wrap::Outer::Inner Wrap::Outer::Inner::Leaf Wrap::Outer])
    end

    it "re-anchors a header inside an eval-family block and under `class <<`" do
      declared = Set["Outer", "Wrap"]

      expect(names("module Wrap; X.class_eval { class Outer::Inner; end }; end\n", declared))
        .to eq(%w[Wrap Outer::Inner Outer])
      expect(names("module Wrap; class << self; class Outer::Inner; end; end; end\n", declared))
        .to eq(%w[Wrap Outer::Inner Outer])
      expect(names("module Wrap; class << (class Outer::Inner; self; end); end; end\n", declared))
        .to eq(%w[Wrap Outer::Inner Outer])
      expect(names("module Wrap; X.class_eval(class Outer::Inner; self; end) { 1 }; end\n", declared))
        .to eq(%w[Wrap Outer::Inner Outer])
    end

    # The base's behaviour, moved as it was: the block and the arguments of a class-creating write are walked with
    # the no-op table.
    it "does not re-anchor a header in the block or the arguments of a constant write that creates a class" do
      declared = Set["Outer", "Wrap"]

      expect(names("module Wrap; K = Class.new { class Outer::Inner; end }; end\n", declared))
        .to eq(%w[Wrap Wrap::K Wrap::Outer::Inner Wrap::Outer])
      expect(names("module Wrap; K = Class.new(class Outer::Inner; self; end); end\n", declared))
        .to eq(%w[Wrap Wrap::K Wrap::Outer::Inner Wrap::Outer])
    end

    it "asks the fold for the table only with project names and a compact header to ask about" do
      renames = ->(text, declared) { described_class.send(:file_compact_header_renames, parse(text), declared) }

      expect(renames.call(source, Set["Outer", "Wrap"])).to eq("Wrap::Outer::Inner" => "Outer::Inner")
      expect(renames.call(source, nil)).to equal(described_class::EMPTY_RENAMES)
      expect(renames.call(source, Set[])).to equal(described_class::EMPTY_RENAMES)
      expect(renames.call("module Wrap; class Inner; end; end\n",
                          Set["Outer"])).to equal(described_class::EMPTY_RENAMES)
    end
  end

  # What another file of `lib/` calls: `ScopeIndexer.index` and `PreEvalConstants`. A second name here is a new way
  # into the module. The one constant is the no-op re-anchoring table.
  it "exposes the entry alone, and the no-op re-anchoring table" do
    expect(described_class.singleton_methods(false)).to eq([:build_declaration_artifacts])
    expect(described_class.constants(false)).to eq([:EMPTY_RENAMES])
    expect(described_class::EMPTY_RENAMES).to eq({}).and be_frozen
  end

  it "leaves none of its 6 functions on ScopeIndexer, public or private, and not its constant" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(6)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
    expect(indexer.const_defined?(:EMPTY_RENAMES, false)).to be(false)
  end

  # The #3318 cut-off counts the functions a moved cluster calls back in what stays, and allows four. This one calls
  # three, all the cross-file fold's: the namespaces a compact name implies, the compact headers the project's names
  # re-anchor, and the name a header has under those.
  it "calls three functions of the indexer, at one site each" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/declaration_artifacts.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == "ScopeIndexer"
    end

    expect(calls).to eq(%i[synthesize_namespace_prefixes compact_header_renames rename_compact_name])
  end

  describe "its callers" do
    def seeded_with(*names)
      empty.with_discovery(empty.discovery.with(discovered_classes: names.to_h { |name| [name, singleton(name)] }))
    end

    it "is the two tables `ScopeIndexer.index` seeds first, re-anchored by the names its scope carries" do
      program = parse("module Wrap; class Outer::Inner; end; end\nK = Struct.new(:a)\n")
      header = program.statements.body.first.body.body.first.constant_path
      seeded = indexer.index(program, default_scope: seeded_with("Outer", "Seed"))[program]
      alone = indexer.index(program, default_scope: empty)[program]

      expect(seeded.discovered_classes.keys).to eq(%w[Outer Seed Wrap Outer::Inner K])
      expect(seeded.discovery.declared_types[header]).to eq(singleton("Outer::Inner"))
      expect(alone.discovered_classes.keys).to eq(%w[Wrap Wrap::Outer::Inner K Wrap::Outer])
      expect(alone.discovery.declared_types[header]).to eq(singleton("Wrap::Outer::Inner"))
    end

    it "is the tables `PreEvalConstants` seeds, with no project names to re-anchor by" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "boot.rb")
        File.write(path,
                   "module Wrap; class Outer::Conf; end; DEFAULT = Outer::Conf; end\nclass Plain; end\nP = Plain\n")
        constants = Rigor::Inference::PreEvalConstants.collect(
          paths: [path], scope_builder: ->(_path) { seeded_with("Outer") }
        )

        expect(constants.transform_values(&:describe))
          .to eq("Wrap::DEFAULT" => "singleton(Wrap::Outer::Conf)", "P" => "singleton(Plain)")
      end
    end
  end

  # The module reads two of the indexer's constants and calls three of its functions, which `scope_indexer.rb`
  # defines: the file requires what else it names, and until the indexer has loaded the entry answers for no
  # program, since the last thing it does is one of those calls.
  def alone_probe
    <<~RUBY
      require "set"
      require "rigor/inference/scope_indexer/declaration_artifacts"
      artifacts = Rigor::Inference::ScopeIndexer::DeclarationArtifacts
      build = lambda do |source, names|
        artifacts.build_declaration_artifacts(Prism.parse(source).value, names)
      rescue NameError => e
        [e.class.name, e.name]
      end
      answers = [["x = 1", nil], ["class A; end", nil], ["class << self; x; end", nil], ["foo { }", nil],
                 ["module W; class O::I; end; end", Set["O"]]].map { |source, names| build.call(source, names) }
      print [Rigor::Inference::ScopeIndexer.respond_to?(:index), defined?(Rigor::Inference::DeclarationWalk::Rules),
             defined?(Rigor::Inference::ScopeIndexer::ClassDeclarations),
             defined?(Rigor::Inference::ScopeIndexer::FactoryCallResolver), defined?(Rigor::Type::Combinator),
             answers].inspect
    RUBY
  end

  it "loads without the indexer, with what it names, and answers for no program" do
    lib = File.join(DeclarationFactSources::REPO_ROOT, "lib")
    out, err, status = RubyRun.capture("-I", lib, "-e", alone_probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, "constant", "constant", "constant", "constant", ' \
                      '[["NoMethodError", :synthesize_namespace_prefixes], ["NoMethodError", :rename_compact_name], ' \
                      '["NameError", :EMPTY_PREFIX], ["NameError", :RECEIVER_EVAL_CALLS], ' \
                      '["NoMethodError", :compact_header_renames]]]')
  end
end
