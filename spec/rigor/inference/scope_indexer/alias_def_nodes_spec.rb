# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::AliasDefNodes` is the alias def-node pass of the methods table. The examples
# of the walk hand `collect_class_alias_map`, through `send`, a parsed snippet and read the map back. The examples of
# the pass run the methods table's own walk over a snippet, as `ScopeIndexer.build_methods_and_def_nodes` does before
# it calls the entry, hand `apply_alias_def_nodes` what that walk filled, and read the def-node slots and the
# contested set: no index is built and no body evaluated. The "alias discovery" examples of `scope_indexer_spec.rb`
# and `spec/integration/alias_then_def_spec.rb` pin what an index and a run make of the slots.
RSpec.describe Rigor::Inference::ScopeIndexer::AliasDefNodes do
  let(:indexer) { Rigor::Inference::ScopeIndexer }

  def parse(source)
    Prism.parse(source).value
  end

  # The `{class => {new name => old name}}` map of a snippet.
  def alias_map(source, accumulator = {})
    described_class.send(:collect_class_alias_map, parse(source), [], accumulator)
  end

  # The map the pass builds for a snippet, which also lists the aliases it met.
  def tracked(source)
    root = parse(source)
    map = described_class::AliasMap.new.track(indexer::Certainty.possible_nodes(root))
    described_class.send(:collect_class_alias_map, root, [], map)
  end

  # The tables the methods table's walk fills for a snippet, before the pass: `[root, def_nodes, tables]`.
  def walked(source)
    root = parse(source)
    tables = indexer::MethodTables.new({}, {}, nil, indexer::Certainty.possible_nodes(root), true)
    tables.root = root
    def_nodes = {}
    indexer.walk_methods_and_def_nodes(root, [], false, tables, def_nodes, nil)
    [root, def_nodes, tables]
  end

  def lines_of(def_nodes)
    def_nodes.transform_values { |slots| slots.transform_values { |node| node.location.start_line } }
  end

  # The pass over a snippet: each slot as the line of the `def` it holds, and the contested slots.
  def pass(source)
    root, def_nodes, tables = walked(source)
    described_class.apply_alias_def_nodes(root, def_nodes, tables)
    [lines_of(def_nodes), tables.contested_def_nodes.to_a]
  end

  describe "the alias map" do
    it "files an `alias` and an `alias_method` call under the class whose body holds them, new name to old" do
      expect(alias_map("class C; def a; end; alias b a; alias_method :c, :a; end\n")).to eq("C" => { b: :a, c: :a })
      expect(alias_map("class C; alias b a; alias b c; end\n")).to eq("C" => { b: :c })
    end

    it "fills the accumulator it was handed and answers it, for a node and for none" do
      seed = { "Z" => {} }

      expect(alias_map("class C; alias b a; end\n", seed)).to equal(seed)
      expect(seed).to eq("Z" => {}, "C" => { b: :a })
      expect(described_class.send(:collect_class_alias_map, nil, [], seed)).to equal(seed)
    end

    it "files nothing outside a class or module body" do
      expect(alias_map("def a; end; alias b a; alias_method :c, :a\n")).to eq({})
    end

    it "qualifies the class by the headers around it, and starts again at a rooted one" do
      source = "module M; class C; alias b a; end; class D::E; alias_method :c, :a; end; " \
               "class ::F; alias g a; end; end\n"

      expect(alias_map(source)).to eq("M::C" => { b: :a }, "M::D::E" => { c: :a }, "F" => { g: :a })
    end

    it "starts from the prefix it is handed" do
      map = described_class.send(:collect_class_alias_map, parse("alias b a\nclass C; alias d c; end\n"), ["Outer"], {})

      expect(map).to eq("Outer" => { b: :a }, "Outer::C" => { d: :c })
    end

    it "reads an alias wherever the class body holds it: a `def` body, a branch, an ordinary block" do
      expect(alias_map("class C; def m; alias b a; alias_method :d, :a; end; end\n")).to eq("C" => { b: :a, d: :a })
      expect(alias_map("class C; if x then alias b a end; [1].each { alias_method :c, :a }; end\n"))
        .to eq("C" => { b: :a, c: :a })
    end

    it "reads an `alias_method` call only on the implicit self with two literal names, and walks on below any call" do
      source = "class C; self.alias_method :b, :a; X.alias_method :c, :a; alias_method 'd', 'a'; alias_method n, :a; " \
               "alias_method(*x); foo(alias_method(:e, :a)); alias_method(:f, :a) { alias g a }; end\n"

      expect(alias_map(source)).to eq("C" => { d: :a, e: :a, f: :a, g: :a })
    end

    it "takes the context it is handed: an unnameable cref with no owner files nothing, an owner files under it" do
      walk = lambda do |owner, **context|
        described_class.send(:collect_class_alias_map, parse("alias b a\nalias_method :c, :a\nalias_method n, :a\n"),
                             ["Outer"], described_class::AliasMap.new.track(nil), owner, **context)
      end

      expect(walk.call(nil)).to eq("Outer" => { b: :a, c: :a })
      expect(walk.call(nil, singleton_cref: true)).to eq({})
      expect(walk.call(nil, singleton_cref: true).events).to eq([])
      expect(walk.call(["Re"], singleton_cref: true)).to eq("Re" => { b: :a, c: :a })
      expect(walk.call(nil, defs_singleton: true)).to eq("Outer" => { c: :a })
    end

    it "does not walk into the names of an `alias`" do
      source = "class C; alias :\"x\#{alias_method :p, :q}\" a; alias b :\"y\#{foo { alias r s }}\"; end\n"

      expect(alias_map(source)).to eq({})
    end

    it "reads an `alias` only when both names are plain symbols, and no alias of a global" do
      expect(alias_map("class C; alias :\"x\#{1}\" a; alias b :\"y\#{2}\"; alias $new $old; alias :c :a; end\n"))
        .to eq("C" => { c: :a })
    end
  end

  describe "a `class <<` body" do
    it "files nothing for an alias written directly in it, bare or under a bare header" do
      source = "class C; class << self; alias b a; alias_method :c, :a; " \
               "class D; alias p q; class E; alias r s; end; end; end; end\n"

      expect(alias_map(source)).to eq({})
    end

    it "starts again at a header that names a path: a rooted one from the top, any other under the prefix" do
      expect(alias_map("class C; class << self; class ::K; alias x y; end; class A::B; alias p q; end; end; end\n"))
        .to eq("K" => { x: :y }, "C::A::B" => { p: :q })
    end

    it "walks the expression in the enclosing context" do
      expect(alias_map("class C; class << (class D; alias b a; self; end); alias x y; end; end\n"))
        .to eq("C::D" => { b: :a })
    end

    it "gives a bare header no prefix to hand on, and declines a `self::` header" do
      expect(alias_map("class C; class << self; class D; class A::B; alias p q; end; end; end; end\n"))
        .to eq("A::B" => { p: :q })
      expect(alias_map("class C; class << self; class self::S; alias b a; end; end; end\n")).to eq({})
    end
  end

  describe "a class or module header" do
    it "anchors a `self::` header on the rebound self around it, and a bare one on the body around" do
      expect(alias_map("class C; K = Class.new { class self::S; alias b a; end; class T; alias c d; end }; end\n"))
        .to eq("C::K::S" => { b: :a }, "C::T" => { c: :d })
    end

    # Prism recovers `class foo` as a header whose path is a call: it names no constant, so nothing below it is
    # filed under a name the header could not spell.
    it "is not walked when it names no constant" do
      root = parse("class foo; alias b a; end\n")

      expect(root.statements.body.first.constant_path).to be_a(Prism::CallNode)
      expect(described_class.send(:collect_class_alias_map, root, [], {})).to eq({})
    end

    it "is walked through its body alone: the superclass is not walked" do
      expect(alias_map("class C < (class D; alias b a; self; end); alias d c; end\n")).to eq("C" => { d: :c })
    end
  end

  describe "a constant write that creates a class" do
    it "files the block's aliases under the class the write names, for each write form" do
      expect(alias_map("class C; K = Class.new { alias b a; alias_method :c, :a }; end\n"))
        .to eq("C::K" => { b: :a, c: :a })
      expect(alias_map("class C; ::K = Class.new { alias b a }; M::N = Struct.new(:x) { alias c d }; end\n"))
        .to eq("K" => { b: :a }, "C::M::N" => { c: :d })
      expect(alias_map("class C; K ||= Class.new { alias b a }; M::N ||= Class.new { alias c d }; end\n"))
        .to eq("C::K" => { b: :a }, "C::M::N" => { c: :d })
    end

    it "keeps the receiver and the arguments of the call in the enclosing context" do
      expect(alias_map("class C; K = Class.new(begin; alias pa pb; Object; end) { alias b a }; end\n"))
        .to eq("C" => { pa: :pb }, "C::K" => { b: :a })
    end

    it "hands the block no prefix of its own: a header inside it is the enclosing body's" do
      expect(alias_map("class C; K = Class.new { class In; alias b a; end }; end\n")).to eq("C::In" => { b: :a })
    end

    it "under `class <<`, files nothing for a bare write and the named class for a path write" do
      source = "class C; class << self; K = Class.new { alias b a }; ::J = Class.new { alias c d }; end; end\n"

      expect(alias_map(source)).to eq("J" => { c: :d })
    end

    it "anchors a `self::` write on the rebound self around it, and files nothing for a target that names nothing" do
      expect(alias_map("class C; X.class_eval { self::K = Class.new { alias b a } }; end\n")).to eq("X::K" => { b: :a })
      expect(alias_map("class C; foo::K = Class.new { alias b a }; end\n")).to eq({})
    end

    it "under `class <<`, keeps the cref unnameable for what the call and its block hold" do
      source = "class C; class << self; ::J = Class.new(class D; alias p q; self; end) { class E; alias r s; end }; " \
               "end; end\n"

      expect(alias_map(source)).to eq({})
    end

    it "is any other write when its value creates no class" do
      expect(alias_map("class C; K = foo { alias b a }; L = 1; end\n")).to eq("C" => { b: :a })
    end
  end

  describe "a block that rebinds `self`" do
    it "files nothing for the block of a class-creating call no write names" do
      expect(alias_map("class C; Class.new { alias b a; alias_method :c, :d }; Struct.new(:x) { alias e f }; end\n"))
        .to eq({})
    end

    it "files an eval-family block's aliases under the receiver, and under the enclosing class for `self` or none" do
      expect(alias_map("class X; end\nmodule M; X.class_eval { alias b a; alias_method :c, :a }; end\n"))
        .to eq("X" => { b: :a, c: :a })
      expect(alias_map("class C; class_eval { alias b a }; self.module_eval { alias_method :e, :f }; end\n"))
        .to eq("C" => { b: :a, e: :f })
    end

    it "reads a `self::` receiver under the enclosing self, and declines it where that self names nothing" do
      expect(alias_map("class C; self::K.class_eval { alias b a }; end\n")).to eq("C::K" => { b: :a })
      expect(alias_map("class C; class << self; self::K.class_eval { alias b a }; end; end\n")).to eq({})
    end

    it "files nothing for a receiver that names no class, nor for an unnameable self under `class <<`" do
      source = "class C; foo.class_eval { alias b a; alias_method :c, :d }; " \
               "class << self; class_eval { alias x y }; end; end\n"

      expect(alias_map(source)).to eq({})
    end

    it "keeps the receiver and the arguments of the call in the enclosing context" do
      expect(alias_map("class C; X.class_eval(begin; alias pa pb; 1; end) { alias b a }; end\n"))
        .to eq("C" => { pa: :pb }, "X" => { b: :a })
      expect(alias_map("class C; K = Class.new { X.class_eval(begin; alias pa pb; 1; end) { alias b a } }; end\n"))
        .to eq("C::K" => { pa: :pb }, "X" => { b: :a })
    end

    it "anchors a receiverless eval inside a class-creating block on the class the write names" do
      source = "class C; K = Class.new { class_eval { alias b a }; instance_eval { alias_method :c, :a } }; end\n"

      expect(alias_map(source)).to eq("C::K" => { b: :a, c: :a })
    end

    it "under `class <<`, keeps the cref unnameable for what the call and its block hold" do
      block = "class C; class << self; X.class_eval { class D; alias p q; end; class ::R; alias r s; end }; end; end\n"
      argument = "class C; class << self; X.class_eval(class D; alias p q; self; end) { 1 }; end; end\n"

      expect(alias_map(block)).to eq("R" => { r: :s })
      expect(alias_map(argument)).to eq({})
    end

    it "is any other call without a block, or with a block that has no body" do
      source = "class C; X.class_eval('alias b a'); X.class_eval { }; Class.new { }; Class.new; X.class_eval(&blk); " \
               "alias c d; end\n"

      expect(alias_map(source)).to eq("C" => { c: :d })
    end
  end

  # Moved from `scope_indexer_spec.rb` with the function it calls: the examples of that group that read the methods
  # table and the visibilities through `ScopeIndexer` stay there.
  describe "eval-block dual context (#1097)" do
    it "does not record a keyword `alias` inside `instance_eval` as an instance alias" do
      # The `alias` keyword binds on the receiver's singleton like `def`; only
      # `alias_method` — a call on the receiver-as-module — is an instance alias.
      aliases = described_class.send(:collect_class_alias_map, parse(<<~RUBY), [], {})
        class X; end
        module M
          X.instance_eval do
            alias kw base
            alias_method :mc, :base
          end
        end
      RUBY
      expect(aliases.fetch("X", {})).to include(mc: :base)
      expect(aliases.fetch("X", {})).not_to have_key(:kw)
    end

    it "splits the two forms under `instance_eval` alone: `class_eval` beside it records both" do
      source = "class X; end\nX.instance_eval { alias kw base }\nX.class_eval { alias ck base }\n"

      expect(alias_map(source)).to eq("X" => { ck: :base })
    end
  end

  describe "the aliases a tracked map lists" do
    def events(source)
      tracked(source).events.map { |klass, new_name, old_name, _at, possible| [klass, new_name, old_name, possible] }
    end

    it "lists each alias it files with its class, its names and whether it is possible, in walk order" do
      map = tracked("class C; alias b a; alias_method :c, :a; if x then alias d a end; end\n")

      expect(map).to eq("C" => { b: :a, c: :a, d: :a })
      expect(events("class C; alias b a; alias_method :c, :a; if x then alias d a end; end\n"))
        .to eq([["C", :b, :a, false], ["C", :c, :a, false], ["C", :d, :a, true]])
      expect(map.events.map { |event| event[3] }).to eq([9, 20, 51])
    end

    it "lists an alias it cannot read, with the new name when that much is plain, and files nothing for it" do
      source = "class C; alias_method n, :a; alias_method :m, n; alias :\"x\#{1}\" a; alias z :\"y\#{2}\"; end\n"

      expect(tracked(source)).to eq({})
      expect(events(source)).to eq([["C", nil, nil, false], ["C", :m, nil, false], ["C", nil, nil, false],
                                    ["C", :z, nil, false]])
    end

    it "lists an unread `alias_method` on `self`, and none on another receiver or of another name" do
      expect(events("class C; self.alias_method :b, :a; X.alias_method n, :a; alias_attribute n, :a; end\n"))
        .to eq([["C", :b, nil, false]])
    end

    it "lists an alias in the arguments of a class-creating write once" do
      expect(events("class C; K = Class.new(begin; alias pa pb; Object; end) { alias b a }; end\n"))
        .to eq([["C", :pa, :pb, false], ["C::K", :b, :a, false]])
    end

    it "lists nothing where it files nothing: outside a class, and directly in a `class <<` body" do
      expect(events("alias b a; alias_method n, :a\nclass C; class << self; alias d c; alias_method n, :c; end; end\n"))
        .to eq([])
    end

    it "lists nothing until it tracks a certainty, and takes a file with none as all certain" do
      root = parse("class C; alias b a if x; end\n")
      untracked = described_class.send(:collect_class_alias_map, root, [], described_class::AliasMap.new)
      certain = described_class.send(:collect_class_alias_map, root, [], described_class::AliasMap.new.track(nil))

      expect(untracked).to eq("C" => { b: :a })
      expect(untracked.events).to be_nil
      expect(certain.events).to eq([["C", :b, :a, 9, false]])
    end
  end

  describe "AliasMap#copy_into" do
    def def_node(source) = parse(source).statements.body.first

    it "adds each alias to the history in source order, as a frozen write that copies what the old name held" do
      map = tracked("class C; alias c b; alias b a; end\n")
      held = def_node("def a; end\n")
      history = { ["C", :a] => [[0, held, true].freeze] }

      expect(map.copy_into(history)).to eq([["C", :c], ["C", :b]])
      expect(history).to eq(["C", :a] => [[0, held, true]], ["C", :c] => [[9, nil, false, :alias]],
                            ["C", :b] => [[20, held, true, :alias]])
      expect(history.fetch(["C", :b]) + history.fetch(["C", :c])).to all(be_frozen)
    end

    it "takes the aliases in source order, whatever order they were listed in" do
      later, earlier = parse("x\ny\n").statements.body.reverse
      held = def_node("def a; end\n")
      map = described_class::AliasMap.new.track(nil)
      map.wrote("C", :c, :b, later)
      map.wrote("C", :b, :a, earlier)
      history = { ["C", :a] => [[-1, held, true]] }

      expect(map.copy_into(history)).to eq([["C", :b], ["C", :c]])
      expect(history.fetch(["C", :c])).to eq([[2, held, true, :alias]])
    end

    it "copies the write before the alias, not a later one, and keeps each name's writes in source order" do
      map = tracked("class C; alias b a; end\n")
      first = def_node("def a = 1\n")
      later = def_node("def a = 2\n")
      history = { ["C", :a] => [[0, first, true], [40, later, true]], ["C", :b] => [[30, later, true]] }

      map.copy_into(history)
      expect(history.fetch(["C", :b])).to eq([[9, first, true, :alias], [30, later, true]])
    end

    it "copies a possible write, or by a possible alias, as possible" do
      held = def_node("def a; end\n")
      possible_alias = tracked("class C; alias b a if x; end\n")
      certain_alias = tracked("class C; alias b a; end\n")
      history = { ["C", :a] => [[0, held, true]] }
      possible = { ["C", :a] => [[0, held, false]] }

      possible_alias.copy_into(history)
      certain_alias.copy_into(possible)
      expect(history.fetch(["C", :b])).to eq([[9, held, false, :alias]])
      expect(possible.fetch(["C", :b])).to eq([[9, held, false, :alias]])
    end

    it "adds a write with no `def` for an old name that held none, and to every earlier name for an unread new name" do
      map = tracked("class C; alias b a; alias_method n, :a; end\n")
      held = def_node("def z; end\n")
      history = { ["C", :a] => [[0, nil, true]], ["C", :z] => [[1, held, true]], ["C", :late] => [[90, held, true]],
                  ["D", :z] => [[2, held, true]] }

      expect(map.copy_into(history)).to eq([["C", :b], ["C", :a], ["C", :z]])
      expect(history.fetch(["C", :b])).to eq([[9, nil, false, :alias], [20, nil, false, :alias]])
      expect(history.fetch(["C", :z])).to eq([[1, held, true], [20, nil, false, :alias]])
      expect(history.fetch(["C", :late])).to eq([[90, held, true]])
      expect(history.fetch(["D", :z])).to eq([[2, held, true]])
    end
  end

  describe ".apply_alias_def_nodes" do
    it "gives the new name the `def` its old name holds, for both forms, and contests nothing" do
      expect(pass("class C\n  def a; end\n  alias b a\n  alias_method :c, :a\nend\n"))
        .to eq([{ "C" => { a: 2, b: 2, c: 2 } }, []])
    end

    it "answers the slots it settled, and settles none for a file with no alias" do
      root, def_nodes, tables = walked("class C\n  def a; end\n  alias b a\nend\nclass D\n  def a; end\nend\n")

      expect(described_class.apply_alias_def_nodes(root, def_nodes, tables)).to eq([["C", :b]])
      expect(described_class.apply_alias_def_nodes(*walked("class C\n  def a; end\nend\n"))).to eq([])
    end

    it "copies what the old name held at the alias: not a `def` written after it" do
      expect(pass("class C\n  def a = 1\n  alias b a\n  def a = 2\n  alias c a\nend\n"))
        .to eq([{ "C" => { a: 4, b: 2, c: 4 } }, []])
    end

    it "copies nothing, and contests the slot, when the old name held no `def` of the file at the alias" do
      expect(pass("class C\n  alias b a\n  def a; end\nend\n")).to eq([{ "C" => { a: 3 } }, [["C", :b]]])
      expect(pass("class C\n  alias b to_s\nend\n")).to eq([{ "C" => {} }, [["C", :b]]])
      expect(pass("class C\n  attr_reader :a\n  alias b a\nend\n")).to eq([{ "C" => {} }, [["C", :b]]])
    end

    it "follows an alias of an alias" do
      expect(pass("class C\n  def a; end\n  alias b a\n  alias c b\nend\n"))
        .to eq([{ "C" => { a: 2, b: 2, c: 2 } }, []])
    end

    it "contests the copy of a possible alias, and of a possible `def`" do
      expect(pass("class C\n  def a; end\n  alias b a if x\nend\n")).to eq([{ "C" => { a: 2, b: 2 } }, [["C", :b]]])
      expect(pass("class C\n  if x\n    def a; end\n  end\n  alias b a\nend\n"))
        .to eq([{ "C" => { a: 3, b: 3 } }, [["C", :a], ["C", :b]]])
    end

    it "clears a contest the slot had when a certain alias copies a certain `def` over it" do
      root, def_nodes, tables = walked("class C\n  def a; end\n  def b; end if x\n  alias b a\nend\n")
      contested_by_the_walk = tables.contested_def_nodes.to_a
      described_class.apply_alias_def_nodes(root, def_nodes, tables)

      expect(contested_by_the_walk).to eq([["C", :b]])
      expect(lines_of(def_nodes)).to eq("C" => { a: 2, b: 2 })
      expect(tables.contested_def_nodes.to_a).to eq([])
    end

    it "leaves the slot to a `def` of the new name written after the alias" do
      expect(pass("class C\n  def a; end\n  alias b a\n  def b; end\nend\n")).to eq([{ "C" => { a: 2, b: 4 } }, []])
    end

    it "keeps the copy, contested, under a later definer that is no `def`" do
      expect(pass("class C\n  def a; end\n  alias b a\n  attr_reader :b\nend\n"))
        .to eq([{ "C" => { a: 2, b: 2 } }, [["C", :b]]])
      expect(pass("class C\n  def a; end\n  alias b a\n  define_method(:b) { }\nend\n"))
        .to eq([{ "C" => { a: 2, b: 2 } }, [["C", :b]]])
    end

    it "keeps the latest copy of several, under a later definer that is no `def`" do
      expect(pass("class C\n  def a; end\n  def c; end\n  alias b a\n  alias b c\n  attr_reader :b\nend\n"))
        .to eq([{ "C" => { a: 2, c: 3, b: 3 } }, [["C", :b]]])
    end

    it "keeps what the slot holds rather than an earlier copy, under a later definer that is no `def`" do
      expect(pass("class C\n  def a; end\n  def b; end\n  alias b a\n  attr_reader :b\nend\n"))
        .to eq([{ "C" => { a: 2, b: 3 } }, [["C", :b]]])
    end

    it "keeps what the slot holds, contested, when an alias that copies nothing replaces it" do
      expect(pass("class C\n  def b; end\n  alias b to_s\nend\n")).to eq([{ "C" => { b: 2 } }, [["C", :b]]])
      expect(pass("class C\n  def a; end\n  def b; end\n  alias_method :b, n\nend\n"))
        .to eq([{ "C" => { a: 2, b: 3 } }, [["C", :b]]])
    end

    it "contests every name of the class written before an alias whose new name it cannot read" do
      expect(pass("class C\n  def a; end\n  def z; end\n  alias_method n, :a\n  def later; end\nend\n"))
        .to eq([{ "C" => { a: 2, z: 3, later: 5 } }, [["C", :a], ["C", :z]]])
    end

    it "settles each class by its own aliases" do
      expect(pass("class C\n  def a; end\n  alias b a\nend\nclass D\n  def a; end\n  alias_method :b, :a\nend\n"))
        .to eq([{ "C" => { a: 2, b: 2 }, "D" => { a: 6, b: 6 } }, []])
    end

    it "leaves the walk's definer history as the walk wrote it" do
      root, def_nodes, tables = walked("class C\n  def a; end\n  alias b a\n  alias_method n, :a\nend\n")
      history = tables.definer_history.transform_values(&:dup)
      described_class.apply_alias_def_nodes(root, def_nodes, tables)

      expect(tables.definer_history).to eq(history)
      expect(history.keys).to eq([["C", :a]])
    end

    it "settles a file whose walk recorded no definer" do
      expect(pass("class C\n  alias b a\nend\n")).to eq([{ "C" => {} }, [["C", :b]]])
    end
  end

  # What another file of `lib/` calls: `ScopeIndexer.build_methods_and_def_nodes`, once. A second name here is a new
  # way into the module. The one constant is the class of the map the pass fills.
  it "exposes the entry alone, and the class of its map" do
    expect(described_class.singleton_methods(false)).to eq([:apply_alias_def_nodes])
    expect(described_class.constants(false)).to eq([:AliasMap])
    expect(described_class::AliasMap.superclass).to be(Hash)
    expect(described_class::AliasMap.public_instance_methods(false).sort).to eq(%i[copy_into events track wrote])
    expect(described_class::AliasMap.private_instance_methods(false)).to eq([:names_before])
  end

  it "leaves none of its 11 functions on ScopeIndexer, public or private, and not the map's class" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(11)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
    expect(indexer.const_defined?(:AliasMap, false)).to be(false)
  end

  # The #3318 cut-off counts the functions a moved cluster calls back in what stays, and allows four. This one calls
  # one: the rule a def-node slot's contest follows its writer by.
  it "calls one function of the indexer, at two sites" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/alias_def_nodes.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == "ScopeIndexer"
    end

    expect(calls).to eq(%i[follow_slot_writer follow_slot_writer])
  end

  it "is the pass the methods table runs after its walk" do
    root = parse("class C\n  def a; end\n  alias b a\n  alias c missing\nend\n")
    _methods, def_nodes, _envelopes, _refinements, siblings = indexer.build_methods_and_def_nodes(root)

    expect(lines_of(def_nodes)).to eq("C" => { a: 2, b: 2 })
    expect(siblings.fetch(:contested_discovered_def_nodes)).to eq(Set[["C", :c]])
  end

  # The module reads one of the indexer's constants and calls one of its functions, which `scope_indexer.rb` defines:
  # the file requires what else it names, and until the indexer has loaded the entry answers only for a program
  # that asks neither.
  def alone_probe
    <<~RUBY
      require "rigor/inference/scope_indexer/alias_def_nodes"
      pass = Rigor::Inference::ScopeIndexer::AliasDefNodes
      tables = Struct.new(:certainty, :definer_history, :contested_def_nodes).new(nil, nil, nil)
      run = lambda do |source|
        def_nodes = {}
        [pass.apply_alias_def_nodes(Prism.parse(source).value, def_nodes, tables), def_nodes]
      rescue NameError => e
        [e.class.name, e.name]
      end
      answers = ["class C; def a; end; class << self; end; K = Class.new; X.class_eval { }; end", "class C; alias b a; end",
                 "class C; X.class_eval { 1 }; end", "class C; Class.new { 1 }; end"].map(&run)
      print [Rigor::Inference::ScopeIndexer.respond_to?(:index), defined?(Rigor::Inference::DeclarationWalk::Rules),
             defined?(Rigor::Inference::ScopeIndexer::Certainty), defined?(Rigor::Source::AliasNames), answers].inspect
    RUBY
  end

  it "loads without the indexer, with what it names, and answers only what needs nothing of the indexer" do
    lib = File.join(DeclarationFactSources::REPO_ROOT, "lib")
    out, err, status = RubyRun.capture("-I", lib, "-e", alone_probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, "constant", "constant", "constant", [[[], {}], ' \
                      '["NoMethodError", :follow_slot_writer], ["NameError", :INSTANCE_EVAL_CALLS], ' \
                      '["NameError", :INSTANCE_EVAL_CALLS]]]')
  end
end
