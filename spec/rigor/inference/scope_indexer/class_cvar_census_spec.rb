# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (U5) — `ScopeIndexer::ClassCvarCensus` is the class-variable census of one file. The examples hand
# its functions a parsed snippet, a scope and, for the three the collector calls, a table, and read the table back:
# no index is built and no body evaluated. `.build_class_cvar_index` is the collector's walk with the superclass
# join; the walker that collector replaced is private and reached through `send`, as the equivalence spec
# (`scope_indexer_class_cvars_equivalence_spec.rb`) reaches it to compare the two over every arm. What the wideners
# and a run make of the table is pinned in `scope_indexer_spec.rb`, `mutated_constant_census_spec.rb` and
# `spec/integration/`.
RSpec.describe Rigor::Inference::ScopeIndexer::ClassCvarCensus do
  let(:combinator) { Rigor::Type::Combinator }
  let(:empty) { Rigor::Scope.empty }

  around do |example|
    saved = ENV.fetch("RIGOR_SHADOW_RULE_WALK", nil)
    ENV.delete("RIGOR_SHADOW_RULE_WALK")
    example.run
  ensure
    saved.nil? ? ENV.delete("RIGOR_SHADOW_RULE_WALK") : ENV.store("RIGOR_SHADOW_RULE_WALK", saved)
  end

  def parse(source) = Prism.parse(source).value

  # A table with each type as its description, and a write that only joins as `join(…)`.
  def described(table)
    table.transform_values do |entries|
      entries.transform_values do |type|
        type.is_a?(described_class::JoinOnlyCvarWrite) ? "join(#{type.type.describe})" : type.describe
      end
    end
  end

  # A scope that knows `Bar` at three depths, so a `Bar.new` rvalue says which chain it was typed under.
  def bars
    classes = %w[Bar M::Bar M::C::Bar].to_h { |name| [name, combinator.singleton_of(name)] }
    empty.with_discovery(empty.discovery.with(discovered_classes: classes))
  end

  describe ".build_class_cvar_index" do
    define_method(:seeds) do |source, scope = empty|
      described(described_class.build_class_cvar_index(parse(source), scope))
    end

    it "answers an empty table for a file that writes no class variable, and for a root that is no node" do
      expect(described_class.build_class_cvar_index(parse("x = 1\n"), empty)).to eq({})
      expect(described_class.build_class_cvar_index(nil, empty)).to eq({})
    end

    it "freezes the table and each class's entries" do
      table = described_class.build_class_cvar_index(parse("class C; def a = (@@a = 1); end\n"), empty)

      expect([table.frozen?, table.fetch("C").frozen?]).to eq([true, true])
    end

    it "files a `def` write, instance or singleton, under the class its header names" do
      expect(seeds("class C\n  def a = (@@a = 1)\n  def self.b = (@@b = :s)\nend\n"))
        .to eq("C" => { :@@a => "1", :@@b => ":s" })
      expect(seeds("module M\n  class C\n    def a = (@@a = 1)\n  end\n  class A::B; def b = (@@b = 2); end\nend\n"))
        .to eq("M::C" => { :@@a => "1" }, "M::A::B" => { :@@b => "2" })
      expect(seeds("module M; class ::R; def a = (@@a = 1); end; end\n")).to eq("R" => { :@@a => "1" })
    end

    it "files nothing for a `def` outside every class" do
      expect(seeds("def a = (@@a = 1)\n")).to eq({})
    end

    it "types a write's rvalue under the chain of the header it is in" do
      expect(seeds("module M\n  class C\n    def a = (@@a = Bar.new)\n  end\n  def b = (@@b = Bar.new)\nend\n", bars))
        .to eq("M::C" => { :@@a => "M::C::Bar" }, "M" => { :@@b => "M::Bar" })
    end

    # Issue #1217 — the cvar twin of the ivar census entry for a target-node write. A rescue reference enters as the
    # unknown floor too, not the exception: the census keys each class alone, so a superclass's `@@last_error = nil`
    # is not in a subclass's entry, and a `StandardError` entry would fold a sibling's `@@last_error.nil?` false.
    %w[class module].each do |keyword|
      it "records a rescue-reference or for-index `@@x` in a #{keyword} as the unknown floor" do
        cvars = described_class.build_class_cvar_index(parse(<<~RUBY), Rigor::Scope.empty)
          #{keyword} Klass
            def run; yield; rescue => @@last_error; end
            def loop_over = (for @@f in [1, 2]; end)
            def plain = (@@n = nil)
          end
        RUBY
        entries = cvars.fetch("Klass")
        expect(entries[:@@last_error]).to eq(Rigor::Type::Combinator.untyped)
        expect(entries[:@@f]).to eq(Rigor::Type::Combinator.untyped)
        expect(entries[:@@n]).to eq(Rigor::Type::Combinator.constant_of(nil))
      end

      # Issue #3204 — a class-body or module-body write joins the entry a `def` body's write of the same class
      # creates, and never creates one: a body-only seed stays unbound (round 1 of #3218's review).
      it "joins a #{keyword}-body `@@x` write into its `def` writes' entry, and creates none" do
        cvars = described_class.build_class_cvar_index(parse(<<~RUBY), Rigor::Scope.empty)
          #{keyword} Klass
            def set = (@@plain = 1)
            @@plain = nil
            [1].each { @@blocked = :b }
            def blocked = (@@blocked = :c)
            @@body_only = nil
            def only_def = (@@d = 1)
          end
        RUBY
        expect(cvars.fetch("Klass")).to eq(
          :@@plain => combinator.union(combinator.constant_of(1), combinator.constant_of(nil)),
          :@@blocked => combinator.union(combinator.constant_of(:c), combinator.constant_of(:b)),
          :@@d => combinator.constant_of(1)
        )
      end
    end

    it "creates no entry for a class whose only cvar writes are in its body" do
      cvars = described_class.build_class_cvar_index(parse(<<~RUBY), Rigor::Scope.empty)
        class Klass
          @@x = nil
          class_variable_set(:@@y, nil)
        end
      RUBY
      expect(cvars).to eq({})
    end

    def cvar_seeds(source)
      described_class.build_class_cvar_index(parse(source), Rigor::Scope.empty)
                     .transform_values { |entries| entries.transform_values(&:describe) }
    end

    it "joins a body write that arrives after the `def` entry exists, through a reopening" do
      expect(cvar_seeds("class C; def s = (@@a = 1); end; class C; @@a = nil; end")).to eq("C" => { :@@a => "1?" })
    end

    it "joins a `class_variable_set` that follows the `def` write" do
      expect(cvar_seeds("class C; def s = (@@x = 1); def t = class_variable_set(:@@x, 5); end"))
        .to eq("C" => { :@@x => "1 | 5" })
    end

    it "keeps every pending body write until the `def` write creates the entry" do
      expect(cvar_seeds("class C; @@a = nil; @@a = :x; def s = (@@a = 1); end"))
        .to eq("C" => { :@@a => "1 | :x | nil" })
    end

    it "creates no entry for a class-body rescue reference or for index alone" do
      expect(cvar_seeds("class C; begin; rescue => @@c; end; for @@f in [1]; end; end")).to eq({})
    end

    it "types a class-body write with the class itself as `self`" do
      cvars = described_class.build_class_cvar_index(parse(<<~RUBY), Rigor::Scope.empty)
        class Klass
          @@me = self
          def m = (@@me = 1)
        end
      RUBY
      expect(cvars.fetch("Klass")[:@@me])
        .to eq(combinator.union(combinator.constant_of(1), combinator.singleton_of("Klass")))
    end

    it "joins a rescue-reference floor with a sibling `def` write in either order" do
      # #3202's review: the target-node entry assigned, so a rescue after the plain write dropped the `1`.
      rescue_def = "def run; yield; rescue => @@c; end"
      seeds = [[rescue_def, "def set = (@@c = 1)"], ["def set = (@@c = 1)", rescue_def]].map do |defs|
        described_class.build_class_cvar_index(parse("class Klass\n#{defs.join("\n")}\nend\n"), Rigor::Scope.empty)
                       .fetch("Klass")[:@@c].describe
      end
      expect(seeds).to eq(["1 | Dynamic[top]", "1 | Dynamic[top]"])
    end

    it "files a nested class's and a `class << self` body's writes on their own cref" do
      cvars = described_class.build_class_cvar_index(parse(<<~RUBY), Rigor::Scope.empty)
        class Outer
          class Inner
            @@i = nil
            def i = (@@i = 1)
          end
          class << self
            @@s = nil
            class Bare
              @@unnamed = nil
              def u = (@@unnamed = 1)
            end
          end
          def s = (@@s = 1)
        end
      RUBY
      nil_or_one = combinator.union(combinator.constant_of(1), combinator.constant_of(nil))
      expect(cvars.fetch("Outer::Inner")).to eq(:@@i => nil_or_one)
      expect(cvars.fetch("Outer")).to eq(:@@s => nil_or_one)
      expect(cvars.keys).to contain_exactly("Outer", "Outer::Inner")
    end

    it "joins `class_variable_set` on an implicit or `self` receiver, and nothing else" do
      cvars = described_class.build_class_cvar_index(parse(<<~RUBY), Rigor::Scope.empty)
        class Other
          def c = (@@c = 1)
        end
        class Klass
          class_variable_set(:@@a, nil)
          self.class_variable_set("@@b", nil)
          Other.class_variable_set(:@@c, nil)
          class_variable_set(:not_a_cvar, nil)
          class_variable_set(name, nil)
          class_variable_set(:@@arity)
          def w = (@@a = @@b = @@arity = @@c = 1)
        end
      RUBY
      nil_or_one = combinator.union(combinator.constant_of(1), combinator.constant_of(nil))
      one = combinator.constant_of(1)
      expect(cvars.fetch("Klass")).to eq(:@@a => nil_or_one, :@@b => nil_or_one, :@@arity => one, :@@c => one)
      expect(cvars.fetch("Other")).to eq(:@@c => one)
    end

    it "keeps `@@x` inside a `def` in a meta-new or eval block on the lexical cref" do
      # MRI: `Module.nesting` is unchanged by `self` rebinding, so `@@x` inside a method
      # defined in `K = Class.new { }` or `X.class_eval { }` belongs to the LEXICAL
      # class C — never to K or X.
      cvars = described_class.build_class_cvar_index(parse(<<~RUBY), Rigor::Scope.empty)
        class X; end
        class C
          K = Class.new do
            def a = (@@va = 1)
          end
          X.class_eval do
            def b = (@@vb = 2)
          end
          X.instance_eval do
            def c = (@@vc = 3)
          end
        end
      RUBY
      expect(cvars.fetch("C")).to include(:@@va, :@@vb, :@@vc)
      expect(cvars).not_to have_key("K")
      expect(cvars).not_to have_key("X")
    end

    describe "under RIGOR_SHADOW_RULE_WALK" do
      let(:source) { "class B; @@c = nil; def self.b = (@@b = :b); end\nclass S < B; def s = (@@c = 1); end\n" }
      let(:divergence) { Rigor::Inference::DeclarationWalk::Shadow::Divergence }

      it "does not run the walker the collector replaced while the flag is unset" do
        allow(described_class).to receive(:legacy_class_cvar_index).and_call_original
        described_class.build_class_cvar_index(parse(source), empty)

        expect(described_class).not_to have_received(:legacy_class_cvar_index)
      end

      it "runs it once under the flag, on the root and the scope it was given" do
        ENV.store("RIGOR_SHADOW_RULE_WALK", "1")
        allow(described_class).to receive(:legacy_class_cvar_index).and_call_original
        root = parse(source)
        scope = empty.with_source_path("app/c.rb")
        described_class.build_class_cvar_index(root, scope)

        expect(described_class).to have_received(:legacy_class_cvar_index).once.with(root, scope)
      end

      # The walker joins nothing along a superclass tree, so the check has to read the collector's table before the
      # join: this source's joined table differs from the walker's, and the flag still stays silent.
      it "checks the collector's table as it is before the superclass join, and answers the joined one" do
        ENV.store("RIGOR_SHADOW_RULE_WALK", "1")

        expect(seeds(source)).to eq("B" => { :@@b => ":b" }, "S" => { :@@c => "1?" })
        expect(described(described_class.send(:legacy_class_cvar_index, parse(source), empty)))
          .to eq("B" => { :@@b => ":b" }, "S" => { :@@c => "1" })
      end

      it "raises a divergence that names the table and the scope's file when the collector's table differs" do
        ENV.store("RIGOR_SHADOW_RULE_WALK", "1")
        collectors = Rigor::Inference::ScopeIndexer::ClassCvarsCollector
        forgetful = Class.new(collectors) do
          def table = {}.freeze
        end
        allow(collectors).to receive(:new).and_return(forgetful.new)

        expect { described_class.build_class_cvar_index(parse(source), empty.with_source_path("app/c.rb")) }
          .to raise_error(divergence,
                          %r{discovery table `class_cvars` for app/c\.rb: the table: key "B" only in legacy})
      end
    end
  end

  # Issue #3219 — a class and its subclasses share one cvar slot, so each entry a `def` write creates joins the writes
  # every class of its in-file superclass tree makes, and a tree whose top names a superclass outside the file joins the
  # unknown floor.
  describe "class-cvar census superclass join (#3219)" do
    def cvar_seeds(source)
      described_class.build_class_cvar_index(parse(source), Rigor::Scope.empty)
                     .transform_values { |entries| entries.transform_values(&:describe) }
    end

    it "joins a superclass's and a subclass's writes into each other's entries" do
      expect(cvar_seeds(<<~RUBY)).to eq("B" => { :@@b => ":b | :s" }, "S" => { :@@c => "1?", :@@b => ":b | :s" })
        class B; @@c = nil; def self.b = (@@b = :b); end
        class S < B; def s = (@@c = 1); def t = (@@b = :s); end
      RUBY
    end

    it "follows a grandparent through the superclass's lexical lookup" do
      expect(cvar_seeds(<<~RUBY)).to eq("M::C" => { :@@c => "1?" })
        module M
          class A; @@c = nil; end
          class B < A; end
          class C < B; def s = (@@c = 1); end
        end
      RUBY
    end

    it "resolves a rooted superclass to the top-level class, not a nearer one" do
      expect(cvar_seeds(<<~RUBY)).to eq("Base" => { :@@c => "1 | :top" }, "M::S" => { :@@c => "1 | :top" })
        class Base; def x = (@@c = :top); end
        module M
          class Base; @@c = nil; end
          class S < ::Base; def s = (@@c = 1); end
        end
      RUBY
    end

    it "floors an entry whose tree names a superclass the file does not declare" do
      expect(cvar_seeds(<<~RUBY)).to eq("S" => { :@@c => "1 | Dynamic[top]" }, "T" => { :@@c => "2 | Dynamic[top]" })
        class S < Unknown; def s = (@@c = 1); end
        class T < Struct.new(:a); def s = (@@c = 2); end
      RUBY
    end

    it "floors an entry whose superclass's nearer candidate another file declares" do
      # `Ns::Base` is declared outside this file, so `class Sub < Base` in `Ns` names it, not the top-level `Base`.
      elsewhere = Rigor::Scope.empty.with_discovery(
        Rigor::Scope::DiscoveryIndex::EMPTY.with(discovered_classes: { "Ns::Base" => :class })
      )
      cvars = described_class.build_class_cvar_index(parse(<<~RUBY), elsewhere)
        class Base; def x = (@@c = :top); end
        module Ns
          class Sub < Base; def s = (@@c = 1); end
        end
      RUBY
      expect(cvars.fetch("Ns::Sub")[:@@c].describe).to eq("1 | Dynamic[top]")
    end

    it "ends a tree at an explicit `Object` superclass" do
      expect(cvar_seeds("class S < Object; def s = (@@c = 1); end")).to eq("S" => { :@@c => "1" })
    end

    it "joins a sibling's write into another sibling's entry" do
      expect(cvar_seeds(<<~RUBY)).to eq("B" => { :@@c => "1?" }, "C" => { :@@c => "1?" })
        class A; end
        class B < A; def s = (@@c = 1); end
        class C < A; def s = (@@c = nil); end
      RUBY
    end

    it "floors a class whose headers name different superclasses" do
      # Ruby raises `superclass mismatch` at the second header; the census reads neither as the superclass.
      expect(cvar_seeds(<<~RUBY).fetch("S")).to eq(:@@c => "1 | Dynamic[top]")
        class A; end
        class B; @@c = nil; end
        class S < A; def s = (@@c = 1); end
        class S < B; end
      RUBY
    end

    it "floors a class whose superclass name is a module the file declares" do
      expect(cvar_seeds(<<~RUBY).fetch("S")).to eq(:@@c => "1 | Dynamic[top]")
        module M; @@c = nil; end
        class S < M; def s = (@@c = 1); end
      RUBY
    end

    it "floors an entry whose superclass's nearer candidate another file's header declares" do
      elsewhere = Rigor::Scope.empty.with_discovery(
        Rigor::Scope::DiscoveryIndex::EMPTY.with(discovered_superclasses: { "Ns::Base" => "Object" })
      )
      cvars = described_class.build_class_cvar_index(parse(<<~RUBY), elsewhere)
        class Base; def x = (@@c = :top); end
        module Ns
          class Sub < Base; def s = (@@c = 1); end
        end
      RUBY
      expect(cvars.fetch("Ns::Sub")[:@@c].describe).to eq("1 | Dynamic[top]")
    end

    it "floors a tree whose headerless top class another file's header gives a superclass" do
      elsewhere = Rigor::Scope.empty.with_discovery(
        Rigor::Scope::DiscoveryIndex::EMPTY.with(discovered_superclasses: { "Base" => "Parent" })
      )
      cvars = described_class.build_class_cvar_index(parse(<<~RUBY), elsewhere)
        class Base; end
        class Sub < Base; def s = (@@c = 1); end
      RUBY
      expect(cvars.fetch("Sub")[:@@c].describe).to eq("1 | Dynamic[top]")
    end

    it "keeps a class `class << self` nests out of the tree" do
      # `class Base` below `class << self` opens `#<Class:Outer>::Base`, which keys nothing, so `Sub < Base`
      # names the top-level `Base`, whose writes hold no `nil`.
      expect(cvar_seeds(<<~RUBY).fetch("Sub")).to eq(:@@c => "1")
        class Outer
          class << self
            class Base; @@c = nil; def b = (@@c = nil); end
          end
        end
        class Base; end
        class Sub < Base; def s = (@@c = 1); end
      RUBY
    end
  end

  # The three functions `ClassCvarsCollector` calls on the walk's events: `on_def` gathers a def's writes,
  # `on_declaration` a class or module body's, and `table` / `hierarchy_table` close the table.
  describe ".collect_def_cvar_writes" do
    def def_node(source) = parse(source).statements.body.first

    define_method(:gathered) do |source, prefix = %w[C], scope = empty, table = {}|
      described_class.collect_def_cvar_writes(def_node(source), prefix, scope, table)
      described(table)
    end

    it "records each write under the joined prefix, typed with an instance of that class as `self`" do
      expect(gathered("def m = (@@a = 1; @@me = self)", %w[M C])).to eq("M::C" => { :@@a => "1", :@@me => "M::C" })
    end

    it "types an rvalue under the chain the prefix spells" do
      expect(gathered("def m = (@@b = Bar.new)", %w[M C], bars)).to eq("M::C" => { :@@b => "M::C::Bar" })
      expect(gathered("def m = (@@b = Bar.new)", %w[M], bars)).to eq("M" => { :@@b => "M::Bar" })
    end

    it "types an rvalue under the chain the scope already carries, when it carries one" do
      scope = bars.with_lexical_nesting(%w[M])

      expect(gathered("def m = (@@b = Bar.new)", %w[M C], scope)).to eq("M::C" => { :@@b => "M::Bar" })
    end

    it "records nothing for a def with no body, or under an empty prefix" do
      expect(gathered("def m; end")).to eq({})
      expect(gathered("def m = (@@a = 1)", [])).to eq({})
    end

    it "unions a write with the entry the table already holds, in either order" do
      table = { "C" => { :@@a => combinator.constant_of(nil) } }

      expect(gathered("def m = (@@a = 1; @@a = :s)", %w[C], empty, table)).to eq("C" => { :@@a => "1 | :s | nil" })
    end

    it "creates the entry a write the table holds as joining was waiting for" do
      table = { "C" => { :@@a => described_class::JoinOnlyCvarWrite.new(combinator.constant_of(nil)) } }

      expect(gathered("def m = (@@a = 1)", %w[C], empty, table)).to eq("C" => { :@@a => "1?" })
    end

    it "reads a write wherever the body holds it, and stops at a nested def, class or module" do
      source = <<~RUBY
        def m
          foo(@@arg = 1)
          [1].each { @@blk = 2 }
          class << self; @@sc = 4; end
          def inner = (@@in = 3)
          class K; @@k = 5; end
          module N; @@n = 6; end
        end
      RUBY

      expect(gathered(source)).to eq("C" => { :@@arg => "1", :@@blk => "2", :@@sc => "4" })
    end

    it "records an empty seed without its emptiness" do
      expect(gathered("def m = (@@s = ''; @@a = []; @@h = {}; @@pair = [1, 2])"))
        .to eq("C" => { :@@s => "String", :@@a => "Array[Dynamic[top]]", :@@h => "Hash[Dynamic[top], Dynamic[top]]",
                        :@@pair => "[1, 2]" })
    end

    it "records no compound write" do
      expect(gathered("def m = (@@a ||= 1; @@b += 1; @@c &&= 2)")).to eq({})
    end

    it "floors a rescue reference and a `for` index, through a splat and a nested target" do
      source = <<~RUBY
        def m
          begin; x; rescue => @@e; end
          for @@f in [1]; end
          for @@g, (@@h, *@@i) in [[1, [2, 3]]]; end
          @@e = 1
        end
      RUBY

      expect(gathered(source)).to eq("C" => { :@@e => "1 | Dynamic[top]", :@@f => "Dynamic[top]",
                                              :@@g => "Dynamic[top]", :@@h => "Dynamic[top]",
                                              :@@i => "Dynamic[top]" })
    end

    # Issue #3204 — `class_variable_set` only joins, in a `def` body too: a name read from a Symbol or a String, on
    # an implicit or `self` receiver, with exactly two arguments.
    it "holds a `class_variable_set` on an implicit or `self` receiver as a joining write" do
      source = <<~RUBY
        def m
          class_variable_set(:@@a, 1)
          self.class_variable_set("@@b", 2)
          Other.class_variable_set(:@@c, 3)
          class_variable_set(name, 4)
          class_variable_set(:@@d)
          class_variable_set(:@@e, 1, 2)
          class_variable_get(:@@f, 6)
          class_variable_set(:@@seed, [])
        end
      RUBY

      expect(gathered(source)).to eq("C" => { :@@a => "join(1)", :@@b => "join(2)",
                                              :@@seed => "join(Array[Dynamic[top]])" })
    end

    it "types a `class_variable_set` value under the same scope as a plain write" do
      expect(gathered("def m = class_variable_set(:@@b, Bar.new)", %w[M C], bars))
        .to eq("M::C" => { :@@b => "join(M::C::Bar)" })
    end
  end

  describe ".collect_body_cvar_writes" do
    def body_of(source) = parse(source).statements.body.first.body

    define_method(:gathered) do |source, prefix = %w[C], scope = empty, table = {}|
      described_class.collect_body_cvar_writes(body_of(source), prefix, scope, table)
      described(table)
    end

    it "holds each write as joining, under the joined prefix, typed with the class itself as `self`" do
      expect(gathered("class C\n  @@x = nil\n  @@me = self\nend\n", %w[M C]))
        .to eq("M::C" => { :@@x => "join(nil)", :@@me => "join(singleton(M::C))" })
    end

    it "types an rvalue under the chain the prefix spells" do
      expect(gathered("class C; @@b = Bar.new; end", %w[M C], bars)).to eq("M::C" => { :@@b => "join(M::C::Bar)" })
    end

    it "reads a block and a `class << self` body, and stops at a def, class or module" do
      source = <<~RUBY
        class C
          [1].each { @@blk = :b }
          class << self; @@sc = 1.0; end
          def w = (@@d = 0)
          class In; @@i = 1; end
          module Mo; @@m = 1; end
        end
      RUBY

      expect(gathered(source)).to eq("C" => { :@@blk => "join(:b)", :@@sc => "join(1.0)" })
    end

    it "records nothing for a body that is nil, or under an empty prefix" do
      table = {}

      expect(described_class.collect_body_cvar_writes(nil, %w[C], empty, table)).to be_nil
      expect(gathered("class C; @@x = 1; end", [], empty, table)).to eq({})
    end

    it "unions joining writes with each other, and joins an entry a def write already made" do
      expect(gathered("class C; @@x = nil; @@x = :s; end")).to eq("C" => { :@@x => "join(:s?)" })

      made = { "C" => { :@@x => combinator.constant_of(1) } }
      expect(gathered("class C; @@x = nil; end", %w[C], empty, made)).to eq("C" => { :@@x => "1?" })
    end

    it "floors a rescue reference and a `for` index as joining writes" do
      expect(gathered("class C; begin; rescue => @@e; end; for @@f in [1]; end; end"))
        .to eq("C" => { :@@e => "join(Dynamic[top])", :@@f => "join(Dynamic[top])" })
    end
  end

  describe ".finished_cvar_census" do
    let(:joining) { described_class::JoinOnlyCvarWrite.new(combinator.constant_of(nil)) }
    let(:one) { combinator.constant_of(1) }

    it "drops each cvar only joining writes reached, and a class left with none" do
      table = { "C" => { :@@kept => one, :@@pending => joining }, "D" => { :@@pending => joining } }

      expect(described_class.finished_cvar_census(table)).to eq("C" => { :@@kept => one })
    end

    it "freezes each entry and the whole, and leaves the table it was given as it was" do
      table = { "C" => { :@@kept => one, :@@pending => joining } }
      finished = described_class.finished_cvar_census(table)

      expect([finished.frozen?, finished.fetch("C").frozen?]).to eq([true, true])
      expect(table).to eq("C" => { :@@kept => one, :@@pending => joining })
      expect([table.frozen?, table.fetch("C").frozen?]).to eq([false, false])
    end

    it "answers an empty frozen table for an empty one" do
      finished = described_class.finished_cvar_census({})

      expect([finished, finished.frozen?]).to eq([{}, true])
    end
  end

  # The walker `ClassCvarsCollector` replaced, which `RIGOR_SHADOW_RULE_WALK` runs as the collector's oracle. It is
  # private, so the examples reach it through `send`; they pin what each of its arms files, with no superclass join.
  describe "the walker the collector replaced" do
    define_method(:walked) do |source, scope = empty|
      described(described_class.send(:legacy_class_cvar_index, parse(source), scope))
    end

    it "answers an empty frozen table for a file that writes nothing, and for a root that is no node" do
      table = described_class.send(:legacy_class_cvar_index, parse("x = 1\n"), empty)

      expect([table, table.frozen?]).to eq([{}, true])
      expect(described_class.send(:legacy_class_cvar_index, nil, empty)).to eq({})
    end

    it "answers the finished census: joining writes dropped, each entry frozen" do
      table = described_class.send(:legacy_class_cvar_index, parse("class C; @@p = nil; def a = (@@a = 1); end"), empty)

      expect(described(table)).to eq("C" => { :@@a => "1" })
      expect(table.fetch("C")).to be_frozen
    end

    describe "a class or module header" do
      it "files a def's writes under the nested, compact or rooted name, and a top-level def's nowhere" do
        source = <<~RUBY
          def top = (@@top = 0)
          module M
            class C
              def a = (@@a = 1)
              def self.b = (@@b = :s)
            end
            class A::B; def c = (@@c = 2); end
            class ::R; def d = (@@d = 3); end
          end
        RUBY

        expect(walked(source)).to eq("M::C" => { :@@a => "1", :@@b => ":s" }, "M::A::B" => { :@@c => "2" },
                                     "R" => { :@@d => "3" })
      end

      it "joins the body's own writes to its defs', typed with the class as `self`" do
        expect(walked("class C\n  @@x = nil\n  @@me = self\n  @@only = 1\n  def w = (@@x = @@me = 0)\nend\n"))
          .to eq("C" => { :@@x => "0?", :@@me => "0 | singleton(C)" })
      end

      it "types a body's own writes and its defs' under the chain its header pushed" do
        source = "module M\n  class C\n    @@b = Bar.new\n    def a = (@@a = @@b = Bar.new)\n  end\nend\n"

        expect(walked(source, bars)).to eq("M::C" => { :@@a => "M::C::Bar", :@@b => "M::C::Bar" })
      end

      it "reads a header with no body as nothing, and goes on" do
        expect(walked("class Empty; end\nclass C; def a = (@@a = 1); end\n")).to eq("C" => { :@@a => "1" })
      end

      it "finds a def a body holds in a block or a branch, and does not enter a def for another" do
        expect(walked("class C\n  [1].each { def a = (@@a = 1) }\n  if x then def b = (@@b = 2) end\nend\n"))
          .to eq("C" => { :@@a => "1", :@@b => "2" })
        expect(walked("class C\n  def a\n    def inner = (@@in = 3)\n  end\nend\n")).to eq({})
      end
    end

    describe "a `class <<` body" do
      it "files a def's writes on the enclosing cref, and leaves a bare header below it ownerless" do
        source = <<~RUBY
          class C
            class << self
              def e = (@@e = 1)
              class Bare; def f = (@@f = 1); end
              class ::Anchored; def g = (@@g = 1); end
            end
          end
        RUBY

        expect(walked(source)).to eq("C" => { :@@e => "1" }, "Anchored" => { :@@g => "1" })
      end

      it "walks its operand in the enclosing context" do
        expect(walked("class C\n  class << (K = Class.new { class self::I; def i = (@@i = 1); end })\n  end\nend\n"))
          .to eq("C::K::I" => { :@@i => "1" })
      end

      # A bare header below `class <<` opens `#<Class:C>::Bare`, which no name reaches: its own writes join nothing,
      # the real `C::Bare` least of all, and a header or a `self::` eval receiver inside it is ownerless too, until a
      # header re-anchors at the root.
      it "keeps a bare header's writes, and whatever it nests, out of a class of the same name" do
        source = <<~RUBY
          class C
            class Bare; def x = (@@u = 1); end
            class << self
              class Bare
                @@u = nil
                def y = (@@v = 2)
                class Deeper; @@w = nil; def d = (@@d = 3); end
                self::Foo.class_eval { class self::InFoo; def z = (@@z = 5); end }
                class ::Top; def t = (@@t = 4); end
              end
            end
          end
        RUBY

        expect(walked(source)).to eq("C::Bare" => { :@@u => "1" }, "Top" => { :@@t => "4" })
      end

      it "keeps its cref below a factory write, an eval block and a bare factory block" do
        source = <<~RUBY
          class C
            class << self
              K = Class.new { class self::I; def i = (@@i = 1); end; class InK; def b = (@@b = 5); end; def k = (@@k = 2) }
              X.class_eval { class self::J; def j = (@@j = 3); end; class InEval; def b = (@@c = 6); end }
              Class.new { class Named; def n = (@@n = 4); end }
              class_eval { class self::Z; def z = (@@z = 7); end }
            end
          end
        RUBY

        expect(walked(source)).to eq("C" => { :@@k => "2" }, "X::J" => { :@@j => "3" })
      end

      # Below an eval the block's self is the receiver, and a `class << self` there opens the receiver's singleton
      # class: nothing in its body is named after the receiver.
      it "drops the self around it: a `self::` name in its body is not the enclosing eval's" do
        source = <<~RUBY
          class X; end
          module M
            X.class_eval do
              class << self
                self::K = Class.new { class self::I; def i = (@@i = 1); end }
                class self::D; def d = (@@d = 2); end
                class_eval { class self::Z; def z = (@@z = 3); end }
              end
            end
          end
        RUBY

        expect(walked(source)).to eq({})
      end

      it "reads one with no body as nothing" do
        expect(walked("class C\n  class << self; end\n  def a = (@@a = 1)\nend\n")).to eq("C" => { :@@a => "1" })
      end
    end

    describe "a constant write whose value is a factory call with a block" do
      it "keeps a def's writes on the lexical cref, and names a `self::` header after the constant" do
        source = <<~RUBY
          class C
            K = Class.new do
              def a = (@@a = 1)
              class self::Inner; def i = (@@i = 2); end
            end
            G ||= Class.new { class self::Guarded; def g = (@@g = 3); end }
            self::P = Class.new { class self::Q; def q = (@@q = 4); end }
            self::O ||= Class.new { class self::R; def r = (@@r = 5); end }
          end
        RUBY

        expect(walked(source)).to eq("C" => { :@@a => "1" }, "C::K::Inner" => { :@@i => "2" },
                                     "C::G::Guarded" => { :@@g => "3" }, "C::P::Q" => { :@@q => "4" },
                                     "C::O::R" => { :@@r => "5" })
      end

      it "walks the factory's arguments in the enclosing context" do
        source = <<~RUBY
          class C
            K = Class.new((Class.new { def q = (@@q = 1) })) do
              def a = (@@a = 2)
            end
          end
        RUBY

        expect(walked(source)).to eq("C" => { :@@q => "1", :@@a => "2" })
      end

      it "reads a block with no body as nothing, and any other constant write as its children" do
        expect(walked("class C\n  K = Class.new { }\n  X = [(def a = (@@a = 1))]\nend\n")).to eq("C" => { :@@a => "1" })
      end
    end

    describe "a factory call with a block that is written to no constant" do
      it "keeps a def's writes on the lexical cref, and gives a `self::` header a self nothing names" do
        source = <<~RUBY
          class C
            Class.new do
              def a = (@@a = 1)
              class self::D; def d = (@@d = 1); end
              class Named; def n = (@@n = 1); end
            end
          end
        RUBY

        expect(walked(source)).to eq("C" => { :@@a => "1" }, "C::Named" => { :@@n => "1" })
      end

      it "walks its receiver and arguments in the enclosing context" do
        source = "class C\n  Class.new((X = Class.new { class self::Y; def y = (@@y = 1); end })) { }\nend\n"

        expect(walked(source)).to eq("C::X::Y" => { :@@y => "1" })
      end

      it "walks one with no block as any other call" do
        expect(walked("class C\n  Class.new((def a = (@@a = 1)))\nend\n")).to eq("C" => { :@@a => "1" })
      end
    end

    describe "an eval-family block" do
      it "keeps a def's writes and a bare header on the lexical cref, and names a `self::` header after the receiver" do
        source = <<~RUBY
          class X; end
          module M
            X.class_eval do
              def b = (@@b = 2)
              class self::Re; def r = (@@r = 1); end
              class Local; def l = (@@l = 1); end
            end
          end
        RUBY

        expect(walked(source)).to eq("M" => { :@@b => "2" }, "X::Re" => { :@@r => "1" }, "M::Local" => { :@@l => "1" })
      end

      it "reads a bare or `self` receiver as the enclosing self" do
        source = <<~RUBY
          module M
            class_eval do
              class self::Z; def z = (@@z = 1); end
            end
            self.instance_eval { class self::S; def s = (@@s = 1); end }
          end
        RUBY

        expect(walked(source)).to eq("M::Z" => { :@@z => "1" }, "M::S" => { :@@s => "1" })
      end

      it "walks its receiver and arguments in the enclosing context, and a block with no body as nothing" do
        source = "module M\n  X.class_eval((K = Class.new { class self::A; def a = (@@a = 1); end })) { }\nend\n"

        expect(walked(source)).to eq("M::K::A" => { :@@a => "1" })
      end

      it "keeps the eval's self below a factory block inside it, and the factory's below an eval" do
        source = <<~RUBY
          class X; end
          class C
            X.class_eval { Class.new { class self::A; def a = (@@a = 1); end } }
            K = Class.new { class_eval { class self::B; def b = (@@b = 1); end } }
          end
        RUBY

        expect(walked(source)).to eq("C::K::B" => { :@@b => "1" })
      end
    end

    # The four places the walker hands an expression on in the context around it: the operand of a `class <<`, and
    # the receiver and arguments of a factory write, of a bare factory call and of an eval call. Each holds a
    # factory written to a constant here, whose block declares a `self::` class with a def that writes a cvar.
    describe "an expression walked in the enclosing context" do
      def factory(name, anchor)
        "(#{anchor}#{name} = Class.new { class self::I#{name}; def i = (@@i#{name.downcase} = 1); end })"
      end

      def four_places(anchor = "")
        <<~RUBY
          class << #{factory('A', anchor)}; end
          B = Class.new(#{factory('C', anchor)}) { }
          Class.new(#{factory('D', anchor)}) { }
          Y.class_eval(#{factory('E', anchor)}) { }
        RUBY
      end

      def named(prefix)
        %w[A C D E].to_h { |name| ["#{prefix}::#{name}::I#{name}", { "@@i#{name.downcase}": "1" }] }
      end

      it "walks each of the four, under the cref around it" do
        expect(walked("module M\n#{four_places}end\n")).to eq(named("M"))
      end

      it "keeps an eval's self around each: a `self::` write there is named after the receiver" do
        expect(walked("class X; end\nmodule M\n  X.class_eval do\n#{four_places('self::')}  end\nend\n"))
          .to eq(named("X"))
      end

      it "keeps the unnameable cref around each: below `class <<` none names a class" do
        expect(walked("class C\n  class << self\n#{four_places}  end\nend\n")).to eq({})
      end
    end
  end

  # What another file calls: `ScopeIndexer.index` the first, `ClassCvarsCollector` the other three. A fifth name here
  # is a new way into the census, and `JoinOnlyCvarWrite` is public because `CvarHierarchy` reads it.
  it "exposes the entry and the three functions the collector calls, and the one constant" do
    expect(described_class.singleton_methods(false).sort)
      .to eq(%i[build_class_cvar_index collect_body_cvar_writes collect_def_cvar_writes finished_cvar_census])
    expect(described_class.constants(false)).to eq([:JoinOnlyCvarWrite])
  end

  it "leaves none of its 13 functions on ScopeIndexer, public or private, nor its constant" do
    functions = described_class.private_instance_methods(false)
    indexer = Rigor::Inference::ScopeIndexer

    expect(functions.size).to eq(13)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
    expect(indexer.const_defined?(:JoinOnlyCvarWrite, false)).to be(false)
  end

  # The #3318 cut-off counts the calls a moved cluster makes back into what stays. This one makes one, at two sites.
  it "calls one function of the indexer, the census scope, at two sites" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/class_cvar_census.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == "ScopeIndexer"
    end

    expect(calls).to eq(%i[census_body_scope census_body_scope])
  end

  # The module reads `EMPTY_NESTING`, `IVAR_BARRIER_NODES` and `BindingTargets` through `ScopeIndexer`'s own names
  # and calls `ScopeIndexer.census_body_scope`, all of which `scope_indexer.rb` defines: the file requires what else
  # it names, and until the indexer has loaded only a call that reaches none of the four answers.
  it "loads without the indexer, with what it names, and answers only what needs nothing of the indexer" do
    probe = <<~RUBY
      require "rigor/inference/scope_indexer/class_cvar_census"
      indexer = Rigor::Inference::ScopeIndexer
      census = indexer::ClassCvarCensus
      walk = Rigor::Inference::DeclarationWalk
      named = [defined?(indexer::ClassCvarsCollector), defined?(indexer::CvarHierarchy), defined?(indexer::EmptySeed),
               defined?(walk::Rules), defined?(walk::Shadow), walk.respond_to?(:run),
               defined?(Rigor::Type::Combinator), Prism::ProgramNode.method_defined?(:rigor_each_child)]
      root = Prism.parse("class C; def m = (@@a = 1); end").value
      def_node = root.statements.body.first.body.body.first
      failure = lambda do |&call|
        call.call
      rescue NameError => e
        [e.class.name, e.name]
      end
      entry = failure.call { census.build_class_cvar_index(root, nil) }
      gather = failure.call { census.collect_def_cvar_writes(def_node, %w[C], nil, {}) }
      skipped = census.collect_def_cvar_writes(def_node, [], nil, {})
      finished = census.finished_cvar_census({ "C" => { a: 1, b: census::JoinOnlyCvarWrite.new(2) } })
      print [indexer.respond_to?(:index), named, entry, gather, skipped, finished].inspect
    RUBY
    out, err, status = RubyRun.capture("-I", File.join(DeclarationFactSources::REPO_ROOT, "lib"), "-e", probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, ["constant", "constant", "constant", "constant", "constant", true, "constant", true], ' \
                      '["NameError", :EMPTY_NESTING], ["NoMethodError", :census_body_scope], nil, {"C" => {a: 1}}]')
  end
end
