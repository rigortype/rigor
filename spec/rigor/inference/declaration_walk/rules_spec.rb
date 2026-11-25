# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/declaration_walk"

# ADR-116 WD9 (R1) — `DeclarationWalk::Rules` holds the declaration-context rules the shared walk and
# `ScopeIndexer`'s hand-written walkers both ask. The examples hand a rule a parsed snippet and the positionals a
# walker would thread: no index is built and no scope is evaluated, so the rule alone decides each answer. The specs
# that pin the same rules through `ScopeIndexer.index` and through a run stay where they are; they also read what a
# walker makes of the answer, which this module cannot show.
RSpec.describe Rigor::Inference::DeclarationWalk::Rules do
  def stmt(source) = Prism.parse(source).value.statements.body.first

  def nodes(source)
    found = []
    walk = lambda do |node|
      found << node
      node.compact_child_nodes.each(&walk)
    end
    walk.call(Prism.parse(source).value)
    found
  end

  def first(source, kind) = nodes(source).find { |node| node.is_a?(kind) }

  def call(source, name) = nodes(source).find { |node| node.is_a?(Prism::CallNode) && node.name == name }

  def slices(list) = list.map(&:slice)

  def declared(source) = described_class.eval_file_declared_names(Prism.parse(source).value).to_a.sort

  describe "the interface" do
    # The functions another file may call. ADR-116's WD9 section admits the module on the condition that this list
    # does not grow: adding an entry is an amendment to that section, and an entry nothing calls any more leaves the
    # module and this list together.
    let(:public_functions) do
      %i[
        class_new_call? collapse_object_owner data_define_call? decl_body_context decl_nameable_under_cref?
        eval_block_split eval_constant_receiver_prefix eval_file_declared_names eval_named_receiver?
        eval_receiver_prefix lexical_nesting_for_prefix meta_call_with_name? meta_new_block_body meta_new_block_call
        meta_new_block_split meta_new_child_prefix meta_new_constant_rvalue? meta_new_path_target_nameable?
        meta_new_rvalue module_new_call? receiver_eval_call? scope_entering_declaration self_anchored_decl_prefix
        self_anchored_tail struct_new_call? struct_new_positionals unnameable_decl? unnameable_eval_self?
        unwrap_freeze_tail
      ]
    end
    # The constants `ScopeIndexer` binds its own names to.
    let(:exported_constants) { %i[EMPTY_NESTING EMPTY_PREFIX INSTANCE_EVAL_CALLS OBJECT_OWNER RECEIVER_EVAL_CALLS] }
    # The list's floor: what the walk asks, and what the files outside the indexer ask.
    let(:walk_roots) do
      %i[decl_body_context eval_block_split meta_new_block_split meta_new_constant_rvalue?
         scope_entering_declaration unnameable_eval_self?]
    end
    let(:entries_called_outside_the_indexer) do
      %i[eval_receiver_prefix meta_new_block_body meta_new_block_call meta_new_constant_rvalue? meta_new_rvalue
         module_new_call? receiver_eval_call?]
    end
    let(:rules_path) { "lib/rigor/inference/declaration_walk/rules.rb" }

    # `{path => [function names]}` for every call on the module in the covered files, read by Prism so that a
    # comment naming a rule does not count. A receiver counts as the gate's rule (v) counts it: `Rules`, or a longer
    # trailing part of the module's name.
    def calls_on_the_module
      DeclarationFactSources.paths_under.each_with_object({}) do |path, calls|
        text = File.read(File.join(DeclarationFactSources::REPO_ROOT, path))
        next unless text.match?(/Rules\s*(?:\.|::)/)

        names = DeclarationFactSources.each_node(Prism.parse(text).value).filter_map do |node|
          receiver = DeclarationFactSources.constant_name(node.receiver) if node.is_a?(Prism::CallNode)
          node.name if receiver && DeclarationWriterScan.names?(receiver, described_class.name)
        end
        calls[path] = names.uniq.sort unless names.empty?
      end
    end

    it "exposes the pinned functions and no other" do
      exposed = described_class.singleton_methods(false)

      expect(exposed - public_functions).to be_empty,
                                            "a function added to DeclarationWalk::Rules' interface is an amendment " \
                                            "to ADR-116's WD9 section, not an edit of this list"
      expect(public_functions - exposed).to be_empty, "an entry that left the module leaves this list too"
    end

    it "exports the pinned constants and no other" do
      expect(described_class.constants.sort).to eq(exported_constants)
    end

    it "keeps the floor callable: what the walk asks, and what the files outside the indexer ask" do
      floor = walk_roots | entries_called_outside_the_indexer

      expect(floor.size).to eq(12)
      expect(floor - described_class.singleton_methods(false)).to be_empty
    end

    it "is asked for the walk's roots by the walk, each spelled on the module" do
      walk = calls_on_the_module.select { |path, _| path.start_with?("lib/rigor/inference/declaration_walk/") }

      expect(walk.keys).to contain_exactly("lib/rigor/inference/declaration_walk/context.rb",
                                           "lib/rigor/inference/declaration_walk/traversal.rb")
      expect(walk.values.flatten.uniq).to match_array(walk_roots)
    end

    it "is asked for the same seven entries by the files outside the indexer" do
      outside = calls_on_the_module.reject do |path, _|
        path.start_with?("lib/rigor/inference/declaration_walk/", "lib/rigor/inference/scope_indexer")
      end

      expect(outside.keys).to contain_exactly(
        "lib/rigor/analysis/dependency_source_inference/walker.rb",
        "lib/rigor/inference/in_effect_refinements/walk.rb", "lib/rigor/inference/module_function_state.rb",
        "lib/rigor/inference/refine_self.rb", "lib/rigor/inference/statement_evaluator.rb"
      )
      expect(outside.values.flatten.uniq).to match_array(entries_called_outside_the_indexer)
    end

    it "is called for nothing that is not a pinned function" do
      expect(calls_on_the_module.values.flatten.uniq - public_functions).to be_empty
    end

    it "names nothing of ScopeIndexer in its code" do
      source = File.read(File.join(DeclarationFactSources::REPO_ROOT, rules_path))
      named = DeclarationFactSources.each_node(Prism.parse(source).value).filter_map do |node|
        case node
        when Prism::ConstantReadNode, Prism::ConstantPathNode then node.slice
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        end
      end

      expect(named.grep(/ScopeIndexer|scope_indexer/)).to be_empty
    end

    it "loads and answers without the indexer" do
      probe = <<~RUBY
        require "rigor/inference/declaration_walk/rules"
        rules = Rigor::Inference::DeclarationWalk::Rules
        body = Prism.parse("module M; class X; end; K = Struct.new(:a); module N; X.class_eval { }; end; end")
                    .value.statements.body.first.body.body
        print [Rigor::Inference.const_defined?(:ScopeIndexer), rules.meta_new_child_prefix(body[1], ["M"]),
               rules.eval_block_split(body[2].body.body.first, ["M", "N"], nil, false).last].inspect
      RUBY
      out, err, status = RubyRun.capture("-I", File.join(DeclarationFactSources::REPO_ROOT, "lib"), "-e", probe)

      expect(status).to be_success, err
      expect(out).to eq('[false, ["M", "K"], ["M", "X"]]')
    end

    it "is the one object behind each name ScopeIndexer binds" do
      indexer = Rigor::Inference::ScopeIndexer

      exported_constants.each do |name|
        expect(indexer.const_get(name)).to equal(described_class.const_get(name)), name.to_s
      end
    end
  end

  describe "the constants" do
    it "lists the six block-taking calls that swap self for the receiver, the instance pair apart" do
      expect(described_class::INSTANCE_EVAL_CALLS).to eq(%i[instance_eval instance_exec]).and be_frozen
      expect(described_class::RECEIVER_EVAL_CALLS)
        .to eq(%i[class_eval module_eval class_exec module_exec instance_eval instance_exec]).and be_frozen
    end

    it "names Object as the owner whose constants are spelled bare, and keeps two empty frozen lists" do
      expect(described_class::OBJECT_OWNER).to eq("Object")
      expect(described_class::EMPTY_NESTING).to eq([]).and be_frozen
      expect(described_class::EMPTY_PREFIX).to eq([]).and be_frozen
    end
  end

  describe ".scope_entering_declaration" do
    let(:scope) { Rigor::Scope.empty }

    def entering(scope, header) = described_class.scope_entering_declaration(scope, stmt(header).constant_path)

    it "starts a chain on a scope that records none" do
      entered = entering(scope, "class Foo; end")

      expect(scope.lexical_nesting).to be_nil
      expect(entered.lexical_nesting).to eq(["Foo"])
    end

    it "pushes one entry per header, qualified against the entry on top" do
      outer = entering(scope, "module Outer; end")

      expect(entering(outer, "class Inner; end").lexical_nesting).to eq(%w[Outer::Inner Outer])
      expect(entering(outer, "class A::B; end").lexical_nesting).to eq(%w[Outer::A::B Outer])
    end

    it "pushes a rooted header unqualified and keeps the enclosing entries beneath it" do
      outer = entering(scope, "module Outer; end")

      expect(entering(outer, "class ::Rooted::Bar; end").lexical_nesting).to eq(%w[Rooted::Bar Outer])
    end

    it "answers nil for no scope, and the scope itself for a path that names no constant" do
      expect(described_class.scope_entering_declaration(nil, stmt("class Foo; end").constant_path)).to be_nil
      expect(described_class.scope_entering_declaration(scope, stmt("not_a_constant"))).to equal(scope)
    end
  end

  describe ".lexical_nesting_for_prefix" do
    it "truncates the prefix at each declaration, innermost first, frozen" do
      expect(described_class.lexical_nesting_for_prefix(%w[A B C])).to eq(%w[A::B::C A::B A]).and be_frozen
      expect(described_class.lexical_nesting_for_prefix([])).to eq([]).and be_frozen
    end
  end

  describe ".unnameable_eval_self?" do
    def unnameable?(...) = described_class.unnameable_eval_self?(...)

    it "is true inside a singleton class body, whatever the prefixes" do
      expect(unnameable?(true, nil, ["A"], false)).to be(true)
    end

    it "is true under a self an eval declined to name, an empty def-owner" do
      expect(unnameable?(false, [], ["A"], false)).to be(true)
      expect(unnameable?(false, nil, ["A"], false)).to be(false)
    end

    it "is true below an unnameable cref only where neither the def-owner nor the prefix names a class" do
      expect(unnameable?(false, nil, [], true)).to be(true)
      expect(unnameable?(false, nil, ["A"], true)).to be(false)
      expect(unnameable?(false, ["K"], [], true)).to be(false)
      expect(unnameable?(false, nil, [], false)).to be(false)
    end
  end

  describe ".meta_new_rvalue" do
    def rvalue(source) = described_class.meta_new_rvalue(stmt(source))

    it "answers the value of each of the four writes that name the class their rvalue creates" do
      expect(rvalue("K = Struct.new(:a)").slice).to eq("Struct.new(:a)")
      expect(rvalue("H::K = Struct.new(:a)").slice).to eq("Struct.new(:a)")
      expect(rvalue("K ||= Struct.new(:a)").slice).to eq("Struct.new(:a)")
      expect(rvalue("H::K ||= Struct.new(:a)").slice).to eq("Struct.new(:a)")
    end

    it "answers nil for any other node: a local write, `&&=`, an operator write, a call" do
      expect(rvalue("k = Struct.new(:a)")).to be_nil
      expect(rvalue("K &&= Struct.new(:a)")).to be_nil
      expect(rvalue("K += 1")).to be_nil
      expect(rvalue("Struct.new(:a)")).to be_nil
    end

    it "strips a `.freeze` tail, repeated tails included, and leaves a value that is no call as it is" do
      expect(rvalue("K = Struct.new(:a) do end.freeze").slice).to eq("Struct.new(:a) do end")
      expect(rvalue("K = Struct.new(:a).freeze.freeze").slice).to eq("Struct.new(:a)")
      expect(rvalue("K = 1").slice).to eq("1")
    end

    it "keeps a tail that is not the plain `.freeze`: `&.freeze`, one with an argument or a block, another method" do
      expect(rvalue("K = Struct.new(:a)&.freeze").slice).to eq("Struct.new(:a)&.freeze")
      expect(rvalue("K = Struct.new(:a).freeze(1)").slice).to eq("Struct.new(:a).freeze(1)")
      expect(rvalue("K = Struct.new(:a).freeze { }").slice).to eq("Struct.new(:a).freeze { }")
      expect(rvalue("K = Struct.new(:a).itself").slice).to eq("Struct.new(:a).itself")
    end

    it "strips a `Const = Const || …` guard for each write spelling, and then the tail" do
      expect(rvalue("K = K || Struct.new(:a)").slice).to eq("Struct.new(:a)")
      expect(rvalue("K ||= K || Struct.new(:a)").slice).to eq("Struct.new(:a)")
      expect(rvalue("H::K = H::K || Struct.new(:a)").slice).to eq("Struct.new(:a)")
      expect(rvalue("H::K ||= H::K || Struct.new(:a)").slice).to eq("Struct.new(:a)")
      expect(rvalue("K = K || Struct.new(:a).freeze").slice).to eq("Struct.new(:a)")
    end

    it "keeps a guard over another name, and one whose written name cannot be read" do
      expect(rvalue("A = B || Struct.new(:a)").slice).to eq("B || Struct.new(:a)")
      expect(rvalue("H::K = K || Struct.new(:a)").slice).to eq("K || Struct.new(:a)")
      expect(rvalue("base::K = base::K || Struct.new(:a)").slice).to eq("base::K || Struct.new(:a)")
    end
  end

  describe ".unwrap_freeze_tail" do
    it "answers the receiver below the tails, and a receiverless `freeze` call as it is" do
      bare = stmt("freeze")

      expect(described_class.unwrap_freeze_tail(stmt("list.freeze.freeze")).slice).to eq("list")
      expect(described_class.unwrap_freeze_tail(bare)).to equal(bare)
    end
  end

  describe ".meta_new_block_call and .meta_new_block_body" do
    it "answers the class-creating call a constant write's rvalue is, through the guard and the tail" do
      expect(described_class.meta_new_block_call(stmt("K = Struct.new(:a)")).slice).to eq("Struct.new(:a)")
      expect(described_class.meta_new_block_call(stmt("K = K || Data.define(:a).freeze")).slice)
        .to eq("Data.define(:a)")
    end

    it "answers nil for a write whose rvalue is no class-creating call" do
      expect(described_class.meta_new_block_call(stmt("K = build(:a)"))).to be_nil
      expect(described_class.meta_new_block_call(stmt("K = 1"))).to be_nil
      expect(described_class.meta_new_block_call(stmt("k = Struct.new(:a)"))).to be_nil
    end

    it "answers the literal block's body, and nil where there is none to read" do
      expect(described_class.meta_new_block_body(stmt("K = Class.new do; def m; end; end")).slice).to eq("def m; end")
      expect(described_class.meta_new_block_body(stmt("K = Class.new"))).to be_nil
      expect(described_class.meta_new_block_body(stmt("K = Class.new { }"))).to be_nil
      expect(described_class.meta_new_block_body(stmt("K = Class.new(&BODY)"))).to be_nil
      expect(described_class.meta_new_block_body(stmt("K = build { }"))).to be_nil
    end
  end

  describe ".meta_new_child_prefix" do
    def prefix(source, *) = described_class.meta_new_child_prefix(stmt(source), *)

    it "appends a bare write's name to the lexical prefix, for `=` and `||=`" do
      expect(prefix("K = Class.new", ["M"])).to eq(%w[M K])
      expect(prefix("K ||= Class.new", ["M"])).to eq(%w[M K])
    end

    it "takes for a path write what a compact header at the same position takes, rooted reset included" do
      expect(prefix("Holder::Thing = Class.new", ["Admin"])).to eq(["Admin", "Holder::Thing"])
      expect(prefix("Holder::Thing ||= Class.new", ["Admin"])).to eq(["Admin", "Holder::Thing"])
      expect(prefix("::Holder::Thing = Class.new", ["Admin"])).to eq(["Holder::Thing"])
    end

    it "anchors a `self::` target on the rebound self, and on the lexical prefix where self is not rebound" do
      expect(prefix("self::S = Class.new", ["C"], ["K"])).to eq(%w[K S])
      expect(prefix("self::S = Class.new", ["C"], [])).to eq([])
      expect(prefix("self::S = Class.new", ["C"])).to eq(%w[C S])
      expect(prefix("self::S = Class.new", ["C"], nil)).to eq(%w[C S])
    end

    it "answers nil for a dynamic base, and for a node that is no constant write" do
      expect(prefix("base::K = Class.new", ["C"])).to be_nil
      expect(prefix("k = Class.new", ["C"])).to be_nil
    end
  end

  describe ".meta_new_block_split" do
    def split(source, *)
      enclosing, body, body_self = described_class.meta_new_block_split(stmt(source), *)
      [slices(enclosing), body&.slice, body_self]
    end

    it "answers the receiver and arguments, the block body, and the class the write names as the body's self" do
      expect(split("K = Class.new(Base, 1) do; def m; end; end", ["M"], nil, false))
        .to eq([%w[Class Base 1], "def m; end", %w[M K]])
      expect(split("K = Struct.new(:a)", ["M"], nil, false)).to eq([%w[Struct :a], nil, %w[M K]])
      expect(split("K = Module.new { def m; end }", [], nil, false)).to eq([%w[Module], "def m; end", %w[K]])
    end

    it "answers nil for a write whose rvalue is no class-creating call" do
      expect(described_class.meta_new_block_split(stmt("K = build { }"), [], nil, false)).to be_nil
    end

    it "gives the body no self below an unnameable cref, unless the write's own path still names its class" do
      expect(split("K = Class.new { }", ["M"], nil, true).last).to eq([])
      expect(split("H::K = Class.new { }", ["M"], nil, true).last).to eq(["M", "H::K"])
      expect(split("self::K = Class.new { }", ["M"], ["Owner"], true).last).to eq(%w[Owner K])
    end

    it "gives the body no self for a write that names nothing, a dynamic base" do
      expect(split("base::K = Class.new { }", ["M"], nil, false).last).to eq([])
    end
  end

  describe ".receiver_eval_call?" do
    it "takes each of the six calls with a literal block" do
      %i[class_eval module_eval class_exec module_exec instance_eval instance_exec].each do |name|
        expect(described_class.receiver_eval_call?(stmt("Foo.#{name} { }"))).to be(true), name.to_s
      end
    end

    it "declines another call, a block argument, a string body and a node that is no call" do
      expect(described_class.receiver_eval_call?(stmt("Foo.each { }"))).to be(false)
      expect(described_class.receiver_eval_call?(stmt("Foo.class_eval(&body)"))).to be(false)
      expect(described_class.receiver_eval_call?(stmt('Foo.class_eval "def m; end"'))).to be(false)
      expect(described_class.receiver_eval_call?(stmt("Foo"))).to be(false)
    end
  end

  describe ".eval_named_receiver?" do
    it "is true for a receiver spelled in source, false for the bare and the `self` forms" do
      expect(described_class.eval_named_receiver?(stmt("Foo.class_eval { }"))).to be(true)
      expect(described_class.eval_named_receiver?(stmt("class_eval { }"))).to be(false)
      expect(described_class.eval_named_receiver?(stmt("self.class_eval { }"))).to be(false)
    end
  end

  describe ".eval_receiver_prefix" do
    def prefix(source, *, **) = described_class.eval_receiver_prefix(stmt(source), *, **)

    it "keeps the enclosing self for a bare or `self` receiver" do
      expect(prefix("class_eval { }", %w[Own], %w[Lex])).to eq(%w[Own])
      expect(prefix("self.class_eval { }", %w[Own], %w[Lex])).to eq(%w[Own])
    end

    it "resolves a `self::` receiver against the enclosing self, and declines it under a self that names nothing" do
      expect(prefix("self::Foo::Bar.class_eval { }", %w[Own], %w[Lex])).to eq(%w[Own Foo Bar])
      expect(prefix("self::Foo.class_eval { }", %w[Own], %w[Lex], unnameable_self: true)).to be_nil
    end

    it "spells a `self::` path rooted at Object bare" do
      expect(prefix("self::Foo.class_eval { }", %w[Object], [])).to eq(%w[Foo])
    end

    it "declines a receiver that renders no static path" do
      expect(prefix("target.class_eval { }", %w[Own], %w[Lex])).to be_nil
      expect(prefix("base::Foo.class_eval { }", %w[Own], %w[Lex])).to be_nil
    end

    it "resolves a constant receiver lexically, not against the enclosing self" do
      node = call("module Own; class Foo; end; end; Foo.class_eval { }", :class_eval)

      expect(described_class.eval_receiver_prefix(node, %w[Own], [])).to eq(%w[Foo])
      expect(described_class.eval_receiver_prefix(node, [], %w[Own])).to eq(%w[Own Foo])
    end
  end

  describe ".eval_constant_receiver_prefix" do
    def resolved(source, lexical_prefix)
      node = call(source, :class_eval)
      rendered = Rigor::Source::ConstantPath.qualified_name_or_nil(node.receiver)
      described_class.eval_constant_receiver_prefix(node, node.receiver, rendered, lexical_prefix)
    end

    it "names the top level for a rooted receiver, ahead of the self-reopen shortcut" do
      expect(resolved("::B.class_eval { }", %w[A B])).to eq(%w[B])
      expect(resolved("::A::B.class_eval { }", %w[A])).to eq(%w[A B])
    end

    it "reads the root off the target of a path write handed in as the path" do
      write = first("module A; X = 1; ::X = 2; end", Prism::ConstantPathWriteNode)

      expect(described_class.eval_constant_receiver_prefix(write, write, "X", %w[A])).to eq(%w[X])
    end

    # A guard: no removal fails it. With no prefix there is no nesting entry to try, so the shortcut it reads and the
    # walk below it answer alike; the shortcut saves the scan of the file's declared names.
    it "keeps the name as written at the top level" do
      expect(resolved("class A; class B; end; end; A::B.class_eval { }", [])).to eq(%w[A B])
    end

    it "answers the lexical prefix for a receiver that reopens the class it is written in" do
      expect(resolved("B.class_eval { }", %w[A B])).to eq(%w[A B])
    end

    it "takes the first nesting entry under which the file declares the receiver's first segment, innermost first" do
      source = <<~RUBY
        module S
          class X; end
          module T
            class X; end
            class U
              X.class_eval { }
            end
          end
        end
      RUBY

      expect(resolved(source, %w[S T U])).to eq(%w[S T X])
      expect(resolved(source.sub("    class X; end\n", ""), %w[S T U])).to eq(%w[S X])
    end

    it "keeps the rest of a multi-segment receiver behind the entry it resolved through" do
      expect(resolved("module S; module A; class B; end; end; A::B.class_eval { }; end", %w[S])).to eq(%w[S A B])
    end

    it "keeps the name as written where no entry declares it" do
      expect(resolved("module S; Other.class_eval { }; end", %w[S])).to eq(%w[Other])
    end
  end

  describe ".eval_block_split" do
    def split(source, *)
      enclosing, body, eval_self = described_class.eval_block_split(call(source, :class_eval), *)
      [slices(enclosing), body.slice, eval_self]
    end

    it "answers the receiver and arguments, the block body, and the prefix the receiver names" do
      expect(split("Foo.class_eval(1, 2) { def m; end }", %w[M], nil, false))
        .to eq([%w[Foo 1 2], "def m; end", %w[Foo]])
    end

    it "answers nil for a call that is no eval-family block" do
      expect(described_class.eval_block_split(stmt("Foo.each { }"), [], nil, false)).to be_nil
    end

    it "keeps the enclosing self for a bare receiver: the rebound owner where there is one, else the prefix" do
      expect(split("class_eval { 1 }", %w[M], nil, false)).to eq([[], "1", %w[M]])
      expect(split("class_eval { 1 }", %w[M], %w[Owner], false)).to eq([[], "1", %w[Owner]])
    end

    it "resolves a `self::` receiver against the rebound owner" do
      expect(split("self::Foo.class_eval { 1 }", %w[M], %w[Owner], false).last).to eq(%w[Owner Foo])
    end

    it "answers no prefix under a self that names nothing, for the bare form and for a `self::` receiver" do
      expect(split("class_eval { 1 }", %w[M], [], false).last).to eq([])
      expect(split("class_eval { 1 }", [], nil, true).last).to eq([])
      expect(split("self::Foo.class_eval { 1 }", %w[M], [], false).last).to eq([])
    end

    it "still names a constant receiver under a self that names nothing, and answers no prefix for a dynamic one" do
      expect(split("Foo.class_eval { 1 }", %w[M], [], true).last).to eq(%w[Foo])
      expect(split("target.class_eval { 1 }", %w[M], nil, false).last).to eq([])
    end
  end

  describe ".eval_file_declared_names" do
    it "holds every class and module a file declares, with each enclosing prefix of its name" do
      expect(declared("module M; class C; end; end; class S::A::B; end")).to eq(%w[M M::C S S::A S::A::B])
    end

    it "resets a rooted header to the top level, and walks a header's superclass expression where it stands" do
      expect(declared("module M; class ::R::S; X = 1; end; end")).to eq(%w[M R R::S R::S::X])
      expect(declared("module M; class C < (Base = Class.new); end; end")).to eq(%w[M M::Base M::C])
    end

    it "holds a bare write of every spelling, and each name of a multiple assignment" do
      expect(declared("module M; A = 1; B ||= 2; C &&= 3; D += 4; E, F = 5, 6; end"))
        .to eq(%w[M M::A M::B M::C M::D M::E M::F])
    end

    it "holds a path write of every spelling as written, not re-anchored under the enclosing class" do
      expect(declared("class S; P::A = 1; P::B ||= 2; P::C &&= 3; P::D += 4; end"))
        .to eq(%w[P P::A P::B P::C P::D S])
    end

    it "resolves a rooted path write at the top level and a `self::` one against the enclosing class" do
      expect(declared("class S; ::R::Q = 1; self::T::U = 2; end")).to eq(%w[R R::Q S S::T S::T::U])
    end

    it "declares nothing for a bare or `self::` name below `class <<`, and still walks the operand and the body" do
      source = <<~RUBY
        class C
          class << (Operand = self)
            X = 1
            Y, Z = 2, 3
            self::W = 4
            class D; Bare = 0; ::InD = 5; end
            class self::E; end
            class F::G; end
            ::Rooted = 6
            pass { Inner = 7 }
          end
        end
      RUBY

      expect(declared(source)).to eq(%w[C C::F C::F::G C::Operand InD Rooted])
    end

    it "skips a def body, where only a `class <<` could declare" do
      expect(declared("class C; def m; class << self; ::InDef = 1; end; end; end")).to eq(%w[C])
    end

    it "declares nothing bare inside a bare factory block, and walks the call's other parts where they stand" do
      expect(declared("module M; Class.new(Sup = Object) { X = 1; ::Y = 2 }; end")).to eq(%w[M M::Sup Y])
      expect(declared("module M; Class.new(Sup = Object); end")).to eq(%w[M M::Sup])
    end

    it "keeps the lexical prefix inside an eval-family block and an ordinary block" do
      expect(declared("module M; Foo.class_eval { class Y; end }; each { Z = 1 }; end")).to eq(%w[M M::Y M::Z])
    end

    it "declares a factory write's block under the name the write gives, and its other parts where they stand" do
      expect(declared("module M; K = Class.new(Sup = Object) { X = 1 }; end")).to eq(%w[M M::K M::K::X M::Sup])
      expect(declared("module M; P::K = Struct.new(:a) { X = 1 }; end")).to eq(%w[M P P::K P::K::X])
      expect(declared("module M; K = (L = 1); J = Class.new(Sup = Object); end")).to eq(%w[M M::J M::K M::L M::Sup])
    end

    it "declares the block of an rvalue that is no factory call under the enclosing prefix" do
      expect(declared("module M; K = build { X = 1 }; end")).to eq(%w[M M::K M::X])
    end

    it "keeps walking a write that names nothing below `class <<`, under the enclosing prefix" do
      source = <<~RUBY
        class C
          class << self
            self::K = Class.new { A = 1; ::Z = 2 }
            N = Class.new { Q = 0; ::V = 3 }
          end
        end
      RUBY

      expect(declared(source)).to eq(%w[C V Z])
    end

    it "answers one frozen set per parse, and a set of its own for another parse of the same text" do
      source = "module M; class C; end; end"
      root = Prism.parse(source).value
      names = described_class.eval_file_declared_names(root)

      expect(names).to be_frozen
      expect(described_class.eval_file_declared_names(root.statements.body.first.body)).to equal(names)
      expect(described_class.eval_file_declared_names(Prism.parse(source).value)).to eq(names)
      expect(described_class.eval_file_declared_names(Prism.parse(source).value)).not_to equal(names)
    end

    context "with the memo audit on" do
      around do |example|
        was = Rigor::MemoAudit.enabled?
        Rigor::MemoAudit.enable!
        example.run
      ensure
        was ? Rigor::MemoAudit.enable! : Rigor::MemoAudit.disable!
        Rigor::MemoAudit.drain
      end

      let(:root) { Prism.parse("module M; class C; end; end").value }
      let(:memo) { Rigor::TypingState.current.weak_key_map(described_class.const_get(:DECLARED_NAMES)) }
      let(:source_key) { root.location.send(:source) }

      it "computes without reading or filling the memo while an audit recomputation runs" do
        memo[source_key] = Set["Stale"].freeze
        suspended = Rigor::MemoAudit.suspended { described_class.eval_file_declared_names(root) }

        expect(suspended.to_a).to eq(%w[M M::C])
        expect(memo[source_key].to_a).to eq(%w[Stale])
      end

      it "stores a miss, and checks a hit against a fresh scan" do
        names = described_class.eval_file_declared_names(root)

        expect(memo[source_key]).to equal(names)
        expect(described_class.eval_file_declared_names(root)).to equal(names)

        memo[source_key] = Set["Stale"].freeze
        expect { described_class.eval_file_declared_names(root) }
          .to raise_error(Rigor::MemoAudit::Mismatch, /scope index declared names/)
      end
    end
  end

  describe ".self_anchored_tail" do
    def tail(source) = described_class.self_anchored_tail(stmt(source))

    it "answers the constant segments below `self`, and nil for any other base or node" do
      expect(tail("self::A::B")).to eq(%w[A B])
      expect(tail("A::B")).to be_nil
      expect(tail("::A")).to be_nil
      expect(tail("base::A")).to be_nil
      expect(tail("A")).to be_nil
      expect(tail("self")).to be_nil
    end
  end

  describe ".collapse_object_owner" do
    it "drops a leading Object, and only that" do
      expect(described_class.collapse_object_owner(%w[Object A])).to eq(%w[A])
      expect(described_class.collapse_object_owner(%w[A Object])).to eq(%w[A Object])
      expect(described_class.collapse_object_owner([])).to eq([])
    end
  end

  describe ".self_anchored_decl_prefix" do
    def prefix(source, self_base) = described_class.self_anchored_decl_prefix(stmt(source), self_base)

    it "names a `self::` path under the rebound self, and nothing under a self no name exists for" do
      expect(prefix("self::A::B", %w[K])).to eq(%w[K A B])
      expect(prefix("self::A", [])).to eq([])
    end

    it "answers nil where self is not rebound, and for a path that is not `self::`" do
      expect(prefix("self::A", nil)).to be_nil
      expect(prefix("A::B", %w[K])).to be_nil
    end
  end

  describe ".decl_nameable_under_cref?" do
    def nameable?(source) = described_class.decl_nameable_under_cref?(stmt(source))

    it "is true for a header whose base resolves lexically, false for a bare, `self::` or dynamic one" do
      expect(nameable?("class ::T; end")).to be(true)
      expect(nameable?("class C::D; end")).to be(true)
      expect(nameable?("class D; end")).to be(false)
      expect(nameable?("class self::D; end")).to be(false)
      expect(nameable?("module base::D; end")).to be(false)
    end
  end

  describe ".unnameable_decl?" do
    def unnameable?(source, *) = described_class.unnameable_decl?(stmt(source), *)

    it "follows the `self::` prefix where the header has one: the empty one declines, a named one re-anchors" do
      expect(unnameable?("class self::D; end", [], false)).to be(true)
      expect(unnameable?("class self::D; end", %w[K D], true)).to be(false)
    end

    it "is otherwise true only below an unnameable cref, for a header that does not name its class there" do
      expect(unnameable?("class D; end", nil, true)).to be(true)
      expect(unnameable?("class C::D; end", nil, true)).to be(false)
      expect(unnameable?("class D; end", nil, false)).to be(false)
    end
  end

  describe ".decl_body_context" do
    def context(source, *) = described_class.decl_body_context(stmt(source), *)

    it "answers the header's `self::` prefix, the body's prefix and the unnameable-cref mark" do
      expect(context("class D; end", %w[C], nil, false)).to eq([nil, %w[C D], false])
      expect(context("class ::D; end", %w[C], nil, false)).to eq([nil, %w[D], false])
      expect(context("class D; end", %w[C], nil, true)).to eq([nil, %w[C D], true])
      expect(context("class self::D; end", %w[C], %w[K], true)).to eq([%w[K D], %w[K D], false])
      expect(context("class self::D; end", %w[C], [], false)).to eq([[], [], true])
      expect(context("class self::D; end", %w[C], nil, false)).to eq([nil, %w[C D], false])
    end

    it "answers nil for a header that renders no prefix" do
      header = Struct.new(:constant_path).new(stmt("not_a_constant"))

      expect(described_class.decl_body_context(header, %w[C], nil, false)).to be_nil
    end
  end

  describe ".meta_new_path_target_nameable?" do
    def nameable?(source, *) = described_class.meta_new_path_target_nameable?(stmt(source), *)

    it "is true for a path write whose base resolves lexically, `=` or `||=`" do
      expect(nameable?("C::K = Class.new")).to be(true)
      expect(nameable?("::K ||= Class.new")).to be(true)
    end

    it "is false for a bare write, and for a dynamic base" do
      expect(nameable?("K = Class.new")).to be(false)
      expect(nameable?("K ||= Class.new")).to be(false)
      expect(nameable?("base::K = Class.new")).to be(false)
    end

    it "follows the rebound self for a `self::` target: a named one names it, none or an empty one does not" do
      expect(nameable?("self::K = Class.new", %w[Owner])).to be(true)
      expect(nameable?("self::K = Class.new", [])).to be(false)
      expect(nameable?("self::K = Class.new")).to be(false)
      expect(nameable?("C::K = Class.new", [])).to be(true)
    end
  end

  describe "the class-creating call recognisers" do
    def recognised(source)
      node = stmt(source)
      %i[class_new_call? module_new_call? data_define_call? struct_new_call?].select do |name|
        described_class.public_send(name, node)
      end
    end

    it "recognises each factory on the bare constant or its rooted spelling" do
      expect(recognised("Class.new(Base)")).to eq(%i[class_new_call?])
      expect(recognised("::Class.new")).to eq(%i[class_new_call?])
      expect(recognised("Module.new")).to eq(%i[module_new_call?])
      expect(recognised("Data.define(:a, :b)")).to eq(%i[data_define_call?])
      expect(recognised("::Struct.new(:a)")).to eq(%i[struct_new_call?])
    end

    it "declines another receiver, another method and a node that is no call" do
      expect(recognised("Ns::Class.new")).to be_empty
      expect(recognised("klass.new")).to be_empty
      expect(recognised("Class.allocate")).to be_empty
      expect(recognised("Data.new(:a)")).to be_empty
      expect(recognised("Struct.define(:a)")).to be_empty
      expect(recognised("1")).to be_empty
    end

    it "takes Data.define with symbol members, a splat, or none, and declines any other argument" do
      expect(recognised("Data.define")).to eq(%i[data_define_call?])
      expect(recognised("Data.define(*FIELDS)")).to eq(%i[data_define_call?])
      expect(recognised('Data.define("a")')).to be_empty
      expect(recognised("Data.define(:a, 1)")).to be_empty
    end

    it "takes Struct.new with a member, a leading name, a splat or a trailing keyword hash" do
      expect(recognised('Struct.new("Named", :a)')).to eq(%i[struct_new_call?])
      expect(recognised("Struct.new(*FIELDS)")).to eq(%i[struct_new_call?])
      expect(recognised("Struct.new(:a, keyword_init: true)")).to eq(%i[struct_new_call?])
    end

    it "declines Struct.new with no positional, or with one that is neither a symbol nor a splat" do
      expect(recognised("Struct.new")).to be_empty
      expect(recognised("Struct.new(keyword_init: true)")).to be_empty
      expect(recognised("Struct.new(:a, 1)")).to be_empty
      expect(recognised('Struct.new(:a, "Named")')).to be_empty
    end

    it "answers whether any of the four recognises the node" do
      ["Class.new", "Module.new", "Data.define(:a)", "Struct.new(:a)"].each do |source|
        expect(described_class.meta_new_constant_rvalue?(stmt(source))).to be(true), source
      end
      expect(described_class.meta_new_constant_rvalue?(stmt("Object.new"))).to be(false)
    end
  end

  describe ".meta_call_with_name? and .struct_new_positionals" do
    it "matches a call by its constant receiver and its method name" do
      expect(described_class.meta_call_with_name?(stmt("Struct.new(:a)"), :Struct, :new)).to be(true)
      expect(described_class.meta_call_with_name?(stmt("Struct.new(:a)"), :Struct, :define)).to be(false)
      expect(described_class.meta_call_with_name?(stmt("Struct.new(:a)"), :Data, :new)).to be(false)
      expect(described_class.meta_call_with_name?(stmt("Struct"), :Struct, :new)).to be(false)
    end

    it "drops a trailing keyword hash from the arguments, and nothing else" do
      keyed = stmt("Struct.new(:a, :b, keyword_init: true)").arguments.arguments
      plain = stmt("Struct.new(:a, :b)").arguments.arguments

      expect(slices(described_class.struct_new_positionals(keyed))).to eq(%w[:a :b])
      expect(described_class.struct_new_positionals(plain)).to equal(plain)
    end
  end
end
