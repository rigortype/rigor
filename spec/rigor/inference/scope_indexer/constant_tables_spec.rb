# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::ConstantTables` holds one file's two constant tables and the rules both ask:
# the typed in-source table (`.build_in_source_constants`), the publication census (`.constant_write_census`) and
# the write-target rules (`.rebound_block_self`, `.dynamic_target_key` and the private ones behind them). The
# examples hand a public function a parsed snippet and, for the typed walk, a scope, and read what comes back: no
# index is built and no body evaluated, apart from the examples that pin the callers. What a run makes of the two
# tables is pinned in `scope_indexer_spec.rb`, `spec/rigor/analysis/` and `spec/integration/`.
RSpec.describe Rigor::Inference::ScopeIndexer::ConstantTables do
  let(:indexer) { Rigor::Inference::ScopeIndexer }
  let(:combinator) { Rigor::Type::Combinator }
  let(:empty) { Rigor::Scope.empty }
  # `ScopeIndexer::OPAQUE_SELF`, which is private there: the self no class or module name reaches.
  let(:opaque) { :__rigor_opaque_self__ }

  def parse(source) = Prism.parse(source).value

  def statement(source) = parse(source).statements.body.first

  # A scope that knows each name as a class some source declares.
  def knowing(*names)
    classes = names.to_h { |name| [name, combinator.singleton_of(name)] }
    empty.with_discovery(empty.discovery.with(discovered_classes: classes))
  end

  describe ".build_in_source_constants" do
    define_method(:typed) do |source, scope = empty|
      described_class.build_in_source_constants(parse(source), scope).transform_values(&:describe)
    end

    it "answers a frozen table, empty for a file that writes no constant and for a root that is no node" do
      table = described_class.build_in_source_constants(parse("X = 1\n"), empty)

      expect([table.frozen?, table.keys]).to eq([true, %w[X]])
      expect(described_class.build_in_source_constants(parse("x = 1\n"), empty)).to eq({})
      expect(described_class.build_in_source_constants(nil, empty)).to eq({})
    end

    it "files a bare write under the class and module bodies around it, nested or compact" do
      expect(typed("X = 1\nY = :a\n")).to eq("X" => "1", "Y" => ":a")
      expect(typed("module A; class B; X = 1; end; end\n")).to eq("A::B::X" => "1")
      expect(typed("class A::B; X = 1; end\n")).to eq("A::B::X" => "1")
      expect(typed("class C; def m; X = 1; end; [1].each { Y = 2 }; end\n")).to eq("C::X" => "1", "C::Y" => "2")
    end

    it "unions the writes of one name" do
      expect(typed("X = 1\nX = :a\n")).to eq("X" => "1 | :a")
    end

    it "records no compound write, and does not walk into a write's rvalue" do
      expect(typed("A ||= 1\nB += 1\nC::D &&= 2\n")).to eq({})
      expect(typed("A = B = 1\nM::C = (D = 2)\n")).to eq("A" => "1", "M::C" => "2")
    end

    it "types an rvalue with the body's class as `self`, and with nothing bound at the top level" do
      expect(typed("class A; REF = self; end\n")).to eq("A::REF" => "singleton(A)")
      expect(typed("module M; class A; REF = self; end; end\n")).to eq("M::A::REF" => "singleton(M::A)")
      expect(typed("REF = self\n")).to eq("REF" => "Dynamic[top]")
    end

    # `Bar` is `M::Bar` under `module M; class C` and the top-level one under the compact `class M::C`, whose
    # `Module.nesting` holds no `M` (#716). A rooted header resets the prefix and not the nesting (#708), so the
    # chain is the one the walk threads on the scope, not one read off the prefix.
    it "types an rvalue under the `Module.nesting` of the body it sits in" do
      scope = knowing("Bar", "M::Bar")

      expect(typed("module M; class C; X = Bar; end; end\n", scope)).to eq("M::C::X" => "singleton(M::Bar)")
      expect(typed("class M::C; X = Bar; end\n", scope)).to eq("M::C::X" => "singleton(Bar)")
      expect(typed("module M; class ::C; X = Bar; end; end\n", scope)).to eq("C::X" => "singleton(M::Bar)")
      expect(typed("X = Bar\n", scope)).to eq("X" => "singleton(Bar)")
    end

    it "records an empty literal without its empty shape" do
      expect(typed("A = []\nH = {}\nS = \"\"\n"))
        .to eq("A" => "Array[Dynamic[top]]", "H" => "Hash[Dynamic[top], Dynamic[top]]", "S" => "String")
    end

    it "types a constant a factory block names as the singleton of its own name" do
      source = "module M; K = Class.new { def m; end }; S = Struct.new(:a) { def m; end }; " \
               "D = Data.define(:x) { def m; end }; N = Module.new { def m; end }; P = Class.new; end\n"

      expect(typed(source)).to eq("M::K" => "singleton(M::K)", "M::S" => "singleton(M::S)", "M::D" => "singleton(M::D)",
                                  "M::N" => "singleton(M::N)", "M::P" => "singleton(Object)")
    end

    describe "a path write" do
      it "keeps the name as written at the top level, and for a rooted path" do
        expect(typed("Foo::BAR = 1\n", knowing("Foo"))).to eq("Foo::BAR" => "1")
        expect(typed("module Admin; ::Holder::DEFAULT = 1; ::TOP = 2; end\n", knowing("Admin::Holder")))
          .to eq("Holder::DEFAULT" => "1", "TOP" => "2")
      end

      # Issue #690 — Ruby resolves the path's namespace through the nesting at the write site.
      it "names the first enclosing namespace a source declares, innermost first" do
        source = "module Admin; module Deep; Holder::X = 1; end; end\n"

        expect(typed(source, knowing("Admin::Holder"))).to eq("Admin::Holder::X" => "1")
        expect(typed(source, knowing("Admin::Holder", "Admin::Deep::Holder"))).to eq("Admin::Deep::Holder::X" => "1")
        expect(typed("module Admin; Holder::Inner::X = 1; end\n", knowing("Admin::Holder::Inner")))
          .to eq("Admin::Holder::Inner::X" => "1")
      end

      it "keeps the name as written when no source declares the namespace under the nesting" do
        expect(typed("module Admin; Holder::DEFAULT = 1; end\n")).to eq("Holder::DEFAULT" => "1")
        expect(typed("module Admin; Holder::Inner::X = 1; end\n", knowing("Admin::Holder")))
          .to eq("Holder::Inner::X" => "1")
      end

      it "takes a class the signatures know for a declared namespace" do
        expect(typed("class File; Stat::X = 1; end\nmodule Zzz; String::Z = 1; end\n"))
          .to eq("File::Stat::X" => "1", "String::Z" => "1")
      end

      it "declines a base that is no static path" do
        expect(typed("k::X = 1\nfoo.bar::Y = 2\n")).to eq({})
      end
    end

    describe "a `self::` write" do
      it "takes the name a bare write in the same body takes" do
        expect(typed("class C; self::X = 1; self::A::B = 2; end\nself::T = 3\n"))
          .to eq("C::X" => "1", "C::A::B" => "2", "T" => "3")
      end

      # Issue #705 — a `class_eval` block moves `self` and not `Module.nesting`.
      it "names the receiver inside an eval-family block, where a bare write keeps the lexical body" do
        source = "module M; Other.class_eval { self::X = 1; Y = 2 }; Other.instance_eval { self::Z = 3 }; end\n"

        expect(typed(source)).to eq("Other::X" => "1", "M::Y" => "2", "Other::Z" => "3")
        expect(typed("module Admin; Other.class_eval { self::REF = self }; end\n"))
          .to eq("Other::REF" => "singleton(Other)")
        expect(typed("module Admin; Other.class_eval { REF = self }; end\n")).to eq("Admin::REF" => "singleton(Other)")
      end

      it "gives the receiver to the block alone, not to the call's arguments" do
        expect(typed("module M; Other.instance_exec(self::A = 1) { self::B = 2 }; end\n"))
          .to eq("M::A" => "1", "Other::B" => "2")
      end

      it "resolves the receiver as a path write's namespace is resolved, and spells `Object`'s constants bare" do
        expect(typed("module Admin; Holder.class_eval { self::X = 1 }; end\n", knowing("Admin::Holder")))
          .to eq("Admin::Holder::X" => "1")
        expect(typed("module Admin; ::Holder.class_eval { self::X = 1 }; end\n", knowing("Admin::Holder")))
          .to eq("Holder::X" => "1")
        expect(typed("Object.class_eval { self::T = 1 }\n")).to eq("T" => "1")
      end

      it "keeps the enclosing self under a receiverless or `self.` eval, and threads it through a `self::` receiver" do
        expect(typed("class C; self.class_eval { self::Z = 1 }; class_eval { self::W = 2 }; end\n"))
          .to eq("C::Z" => "1", "C::W" => "2")
        expect(typed("Y.class_eval { self::X.class_eval { self::Z = 1 } }\n")).to eq("Y::X::Z" => "1")
      end

      it "is declined where the block's self reaches no name, and the bare write beside it is kept" do
        expect(typed("x.class_eval { self::Z = 1; W = 2 }\n")).to eq("W" => "2")
        expect(typed("class C; define_method(:m) { self::X = 1 }; Class.new { self::Y = 2 }; end\n")).to eq({})
        expect(typed("x.class_eval { self::A.class_eval { self::B = 1 } }\n")).to eq({})
      end

      it "is the enclosing body's inside an ordinary block" do
        expect(typed("class C; [1].each { self::X = 1 }; end\n")).to eq("C::X" => "1")
      end
    end

    describe "a `class <<` body" do
      it "declines a bare and a `self::` write, which land on the singleton's own table" do
        expect(typed("class C; class << self; self::X = 1; W = 2; end; end\n")).to eq({})
      end

      it "walks its operand in the body around it" do
        expect(typed("class C; class << (X = 1; self); end; end\n")).to eq("C::X" => "1")
      end

      it "keeps declining below a bare header and inside a block, and names again below a rooted header" do
        expect(typed("class C; class << self; class D; X = 1; self::Y = 2; end; end; end\n")).to eq({})
        expect(typed("class C; class << self; class self::D; X = 1; end; end; end\n")).to eq({})
        expect(typed("class C; class << self; class ::D; X = 1; end; end; end\n")).to eq("D::X" => "1")
        expect(typed("class C; class << self; Foo.class_eval { X = 1; self::Y = 2 }; end; end\n"))
          .to eq("Foo::Y" => "2")
      end

      # `Foo` inside `#<Class:C>::D` resolves through `[C, Object]`: the only nameable rungs are the enclosing ones.
      it "resolves a path write below a bare header through the enclosing prefix, never through the header's" do
        source = "class C; class << self; class D; Foo::BAR = 1; end; end; end\n"

        expect(typed(source, knowing("C::D::Foo"))).to eq("Foo::BAR" => "1")
        expect(typed(source, knowing("C::Foo"))).to eq("C::Foo::BAR" => "1")
        expect(typed("class C; class << self; class D; class Foo::Inner; X = 1; end; end; end; end\n"))
          .to eq("C::Foo::Inner::X" => "1")
      end
    end

    it "opens a `self::` header under the enclosing self, and a plain header as a self of its own" do
      expect(typed("class C; class self::D; X = 1; end; end\n")).to eq("C::D::X" => "1")
      expect(typed("Other.class_eval { class self::D; X = 1; end }\n")).to eq("Other::D::X" => "1")
      expect(typed("Other.class_eval { class Inner; self::X = 1; end }\n")).to eq("Inner::X" => "1")
      expect(typed("Class.new { class self::D; X = 1; end }\n")).to eq({})
    end

    # Prism recovers `class foo` as a header whose path is a call: it names no constant.
    it "walks a header through its body alone, and one with no body or no constant name as any other node" do
      expect(typed("class C < (S = 1; Base); X = 2; end\n")).to eq("C::X" => "2")
      expect(typed("class C < (S = 1; Base); end\nmodule M; end\n")).to eq("S" => "1")
      expect(typed("class foo; X = 1; end\n")).to eq("X" => "1")
    end

    # ADR-46 — the key of a path write moves with another file's class declarations, so each probe of the nesting
    # records its own edge while a dependency recording is open: the declaring file of the namespace that hit, and
    # a `class:` miss for each candidate that did not.
    describe "under a dependency recording" do
      let(:recorder) { Rigor::Analysis::DependencyRecorder }
      let(:scope) do
        known = knowing("Admin::Holder")
        known.with_discovery(known.discovery.with(discovered_class_sources: { "Admin::Holder" => Set["/app/h.rb:3"] }))
      end

      it "reads the file that declares the namespace it resolved through, and misses each candidate that is none" do
        record = recorder.record_for("a.rb") do
          typed("module Admin; Holder::X = 1; Other::Y = 2; end\n", scope)
        end

        expect([record.sources.to_a, record.missing.to_a]).to eq([["/app/h.rb"], ["class:Other"]])
      end

      it "records nothing for a write the nesting does not qualify, or with no recording open" do
        record = recorder.record_for("a.rb") { typed("Holder::X = 1\nmodule Admin; ::A::B = 2; end\n", scope) }

        expect([record.sources.to_a, record.missing.to_a]).to eq([[], []])
        expect(typed("module Admin; Holder::X = 1; end\n", scope)).to eq("Admin::Holder::X" => "1")
      end
    end
  end

  describe ".constant_write_census" do
    def census(source) = described_class.constant_write_census(parse(source))

    def writes(source) = census(source).writes

    it "answers the tables of one walk, each empty for a file that writes no constant" do
      tables = census("x = 1\n")

      expect([tables.writes, tables.seen, tables.declared, tables.aliases]).to eq([{}, Set[], Set[], {}])
      expect(tables.write_census).to be_a(Rigor::Inference::GlobalWriteCensus::Collector)
      expect(described_class.constant_write_census(nil).writes).to eq({})
    end

    it "publishes a Symbol, an Integer, a Float, `true` and `false`, each as a one-element Array" do
      expect(writes("A = :s\nB = 1\nC = 1.5\nD = true\nE = false\n"))
        .to eq("A" => [:s], "B" => [1], "C" => [1.5], "D" => [true], "E" => [false])
    end

    it "files every other rvalue as unpublishable" do
      source = "F = nil\nG = \"s\"\nH = []\nI = foo\nJ = :\"a\#{x}\"\nK = Other\n"

      expect(writes(source)).to eq(%w[F G H I J K].to_h { |name| [name, :unpublishable] })
    end

    it "retracts a name the file writes twice, whatever either rvalue was" do
      expect(writes("X = :a if c\nX = :b\n")).to eq("X" => :unpublishable)
    end

    it "files an operator write unpublishable, bare or as a path" do
      expect(writes("A += 1\nB &&= 1\nC::D += 1\nC::E &&= 2\n"))
        .to eq("A" => :unpublishable, "B" => :unpublishable, "C::D" => :unpublishable, "C::E" => :unpublishable)
      expect(writes("module M; A += 1; B ||= 2; end\n")).to eq("M::A" => :unpublishable, "M::B" => :memo)
    end

    it "files each constant target of a multiple assignment unpublishable, and a path target under the wildcard key" do
      expect(writes("module M; A, B = :x, :y; c, D = 1, 2; *e, F = 3, 4; end\n"))
        .to eq(%w[M::A M::B M::D M::F].to_h { |name| [name, :unpublishable] })
      expect(writes("E::F, g = 1, 2\nclass C; self::H, i = 3, 4; end\n"))
        .to eq("*::F" => :unpublishable, "*::H" => :unpublishable)
    end

    it "walks into a write's rvalue, so the inner write of a chain is censused too" do
      expect(writes("C = D = :x\n")).to eq("C" => :unpublishable, "D" => [:x])
    end

    it "qualifies a bare write by the bodies around it, and keeps a path write as written" do
      expect(writes("module M; class K; X = 1; end; end\nclass A::B; Y = 2; end\n"))
        .to eq("M::K::X" => [1], "A::B::Y" => [2])
      expect(writes("module M; Foo::BAR = 1; ::Top::X = 2; end\n")).to eq("Foo::BAR" => [1], "Top::X" => [2])
    end

    describe "a `self::` write" do
      it "names the enclosing body, the receiver of an eval-family block, and `Object`'s constants bare" do
        expect(writes("class C; self::X = 1; self::A::B = 2; end\n")).to eq("C::X" => [1], "C::A::B" => [2])
        expect(writes("module M; Other.class_eval { self::X = 1; Y = 2 }; end\n"))
          .to eq("Other::X" => [1], "M::Y" => [2])
        expect(writes("Object.class_eval { self::T = 1 }\n")).to eq("T" => [1])
        expect(writes("Other.class_eval { self::X ||= 1; self::Y += 1 }\n"))
          .to eq("Other::X" => :memo, "Other::Y" => :unpublishable)
      end

      it "threads the receiver through a `self::` receiver, and gives it to the block alone" do
        expect(writes("Y.class_eval { self::X.class_eval { self::Z = 1 } }\n")).to eq("Y::X::Z" => [1])
        expect(writes("module M; Other.instance_exec(self::A = 1) { self::B = 2 }; end\n"))
          .to eq("M::A" => [1], "Other::B" => [2])
      end

      # Issue #710 — Ruby names the constructed class after the constant it is first assigned to.
      it "names the constant a factory block's class is assigned to, through a `.freeze` tail too" do
        expect(writes("module M; K = Class.new { self::X = 1 }; end\n"))
          .to eq("M::K" => :unpublishable, "M::K::X" => [1])
        expect(writes("K = Struct.new(:a) { self::X = 1 }.freeze\n")).to eq("K" => :unpublishable, "K::X" => [1])
        expect(writes("K = Class.new { class self::D; X = 1; end }\n"))
          .to eq("K" => :unpublishable, "K::D::X" => [1])
      end

      # Issue #963, #703 — an or-write may not run its rvalue, and a path write is keyed as written here.
      it "falls back to the wildcard key where nothing names the block's class" do
        expect(writes("N::Made = Class.new { self::X = 1 }\n"))
          .to eq("N::Made" => :unpublishable, "*::X" => :unpublishable)
        expect(writes("K ||= Class.new { self::X = 1 }\n")).to eq("K" => :memo, "*::X" => :unpublishable)
        expect(writes("K = wrap(Class.new { self::X = 1 })\n")).to eq("K" => :unpublishable, "*::X" => :unpublishable)
        expect(writes("K = Class.new { Class.new { self::Y = 1 } }\n"))
          .to eq("K" => :unpublishable, "*::Y" => :unpublishable)
        expect(writes("Class.new { self::X = 1 }\nclass C; define_method(:m) { self::Y = 1 }; end\n"))
          .to eq("*::X" => :unpublishable, "*::Y" => :unpublishable)
        expect(writes("x.class_eval { self::Z = 1; W = 2 }\n")).to eq("*::Z" => :unpublishable, "W" => [2])
      end
    end

    # Issue #668 — a write through a base no name reaches is filed under `*::<last segment>`, with no value.
    it "files a write through a dynamic base under the wildcard key, with no value" do
      expect(writes("k::X = 1\n[Foo].each { |k| k::Y = 2 }\n"))
        .to eq("*::X" => :unpublishable, "*::Y" => :unpublishable)
      expect(writes("k::X ||= 1\nk::Y += 1\na, k::Z = 1, 2\n"))
        .to eq("*::X" => :memo, "*::Y" => :unpublishable, "*::Z" => :unpublishable)
    end

    # Issue #710 — `declared` is the half the local-declaration exemption reads: a wildcard key is in `writes`, since
    # another file's value for a name it reaches is not to be trusted, and not in `declared`.
    it "lists as declared the writes that name their target, and as seen every key" do
      tables = census("A = 1\nclass C; self::B = 2; end\nk::X = 3\nClass.new { self::Y = 4 }\nD, k::Z = 5, 6\n" \
                      "k::W += 1\n")

      expect(tables.declared).to eq(Set["A", "C::B", "D"])
      expect(tables.seen).to eq(Set["A", "C::B", "*::X", "*::Y", "D", "*::Z", "*::W"])
    end

    # Issue #667 — the one unpublishable rvalue whose provenance is still knowable.
    describe "aliases" do
      it "records the constant a plain write's rvalue names, qualified as written" do
        tables = census("MODE2 = AppConfig::MODE\nM3 = MODE\nmodule M; M4 = ::Top; Foo::M5 = Bar; end\nM6 = foo::Baz\n")

        expect(tables.aliases).to eq("MODE2" => "AppConfig::MODE", "M3" => "MODE", "M::M4" => "Top", "Foo::M5" => "Bar",
                                     "M6" => "Baz")
      end

      it "drops a name written twice, and records none for a compound write or a key nothing names" do
        expect(census("MODE2 = A\nMODE2 = B\n").aliases).to eq({})
        expect(census("X = 1\nX = A\n").aliases).to eq({})
        expect(census("M ||= A\nk::N = B\n").aliases).to eq({})
      end
    end

    # A write inside a `class <<` body lands on the singleton's own constant table, a name nothing else can produce.
    describe "a `class <<` body" do
      it "declines `self::` and bare constant writes inside a `class <<` body" do
        # Both forms write the singleton's own constant table — `#<Class:Y>::X` — a name
        # nothing else can produce, so neither files under `Y` nor retracts `X`.
        writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
          class Y
            class << self
              self::X = 1
              W = 2
            end
          end
        RUBY
        expect(writes).to be_empty
      end

      it "declines bare writes inside eval/meta blocks under `class <<` — cref never rebinds" do
        # `Module.nesting` stays lexical through every block: the write lands on
        # `#<Class:C>::X`, a name nothing else can produce, in each form.
        writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
          class Foo; end
          class C
            class << self
              Foo.class_eval { X = 1 }
              obj.instance_eval { Y = 1 }
              K = Class.new { Z = 1 }
            end
          end
        RUBY
        expect(writes.keys).to be_empty
      end

      it "declines `self::` writes inside a meta-new block under `class <<`" do
        # `K` itself is unnameable, so the block's anonymous class is too — `self::Y`
        # there cannot be spelled `C::K::Y`.
        writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
          class C
            class << self
              K = Class.new { self::Y = 1 }
            end
          end
        RUBY
        expect(writes.keys).to be_empty
      end

      it "keys a path write inside `class D` under `class <<` as written, never `C::D`-qualified" do
        # `Foo::BAR` inside `#<Class:C>::D` resolves `Foo` through `[C, Object]` — the census
        # keys the write AS WRITTEN; what it must never fabricate is a `C::D::Foo::BAR` rung.
        writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
          class C
            class << self
              class D
                Foo::BAR = 1
              end
            end
          end
        RUBY
        expect(writes.keys).to include("Foo::BAR")
        expect(writes.keys).not_to include("C::D::Foo::BAR")
      end

      it "keys `self::V` inside a rooted meta-new block under the class it names" do
        # `self` inside `::K = Struct.new do … end` is `K` — `self::V` writes `K::V`.
        writes = described_class.send(:constant_writes_for_file, parse(<<~RUBY))
          class C
            class << self
              ::K = Struct.new(:x) do
                self::V = 1
              end.freeze
            end
          end
        RUBY
        expect(writes.keys).to include("K::V")
      end

      it "declines every other bare and `self::` form too, and keeps a path and a rooted write" do
        source = "class Y; class << self; A, b = 1, 2; C ||= 1; self::D += 1; Foo::BAR = 1; ::Z = 2; end; end\n"

        expect(writes(source)).to eq("Foo::BAR" => [1], "Z" => [2])
      end

      it "walks its operand in the body around it, and names again below a rooted header" do
        expect(writes("class C; class << (X = 1; self); end; end\n")).to eq("C::X" => [1])
        expect(writes("class C; class << self; class D; X = 1; self::Y = 2; end; class ::E; Y = 2; end; end; end\n"))
          .to eq("E::Y" => [2])
      end

      it "keeps declining below a `self::` header, and opens a path header below a bare one under the prefix around" do
        expect(writes("class C; class << self; class self::D; X = 1; Foo::Y = 2; end; end; end\n"))
          .to eq("Foo::Y" => [2])
        expect(writes("class C; class << self; class D; class Foo::Inner; X = 1; end; end; end; end\n"))
          .to eq("C::Foo::Inner::X" => [1])
      end

      it "names the receiver of an eval-family block again" do
        expect(writes("class C; class << self; Foo.class_eval { self::Y = 2 }; end; end\n")).to eq("Foo::Y" => [2])
      end

      it "names a factory block's class through a definite path write alone" do
        source = "class C; class << self; A::K2 = Class.new { self::V = 1 }; K3 ||= Class.new { self::W = 2 }; end; " \
                 "end\n"

        expect(writes(source)).to eq("A::K2" => :unpublishable, "C::A::K2::V" => [1])
        expect(writes("class C; class << self; self::K = Class.new { self::V = 1 }; end; end\n")).to eq({})
        expect(writes("class C; class << self; A::K4 ||= Class.new { self::U = 3 }; end; end\n"))
          .to eq("A::K4" => :memo)
      end
    end

    it "opens a `self::` header under the enclosing self, and a plain header as a self of its own" do
      expect(writes("class C; class self::D; X = 1; end; end\nclass E; end\n")).to eq("C::D::X" => [1])
      expect(writes("Other.class_eval { class self::D; X = 1; end }\n")).to eq("Other::D::X" => [1])
      expect(writes("Other.class_eval { class Inner; self::X = 1; end }\n")).to eq("Inner::X" => [1])
    end

    it "gives a header no name from the write it is the rvalue of, and declines one under a self nothing names" do
      expect(writes("K = class self::D; X = 1; end\n")).to eq("K" => :unpublishable, "D::X" => [1])
      expect(writes("Class.new { class self::D; X = 1; end }\n")).to eq({})
    end

    # Prism recovers `class foo` as a header whose path is a call: it names no constant, and nothing below it is
    # censused under a name the header could not spell.
    it "does not walk a header that names no constant" do
      expect(writes("class foo; X = 1; end\n")).to eq({})
    end

    # Issue #1367, #1154, #2488 — the same walk feeds the file's `GlobalWriteCensus`, with the class whose instance
    # `def`s it credits and the class an explicit-receiver writer call names.
    describe "the write census it feeds" do
      def own_writes(source) = census(source).write_census.census.to_a

      it "credits an ivar write to the lexical class, or to the class a block opens" do
        expect(own_writes("module M; class C; def m; @a = 1; end; end; end\n"))
          .to eq([[:own_write_type, "M::C", :@a, [:lit, 1]], [:own_write, "M::C", :@a]])
        expect(own_writes("K = Struct.new(:a) { def m; @a = 1; end }\n")).to include([:own_write, "K", :@a])
        expect(own_writes("module M; K.class_eval { def m; @a = 1; end }; end\n")).to include([:own_write, "K", :@a])
      end

      it "credits none at the top level, under `class <<` or in a block whose self reaches no name" do
        expect(own_writes("def m; @a = 1; end\n")).to eq([])
        expect(own_writes("class C; class << self; def m; @a = 1; end; end; end\n")).to eq([])
        expect(own_writes("class C; Class.new { def m; @a = 1; end }; end\n")).to eq([])
      end

      it "names the class an explicit-receiver writer call is on, as an eval receiver is named" do
        expect(own_writes("module M; E.attr_writer :w; end\n")).to eq([[:own_write_type, "E", :@w, :dynamic]])
        expect(own_writes("class C; self::E.attr_writer :w; end\n")).to eq([[:own_write_type, "C::E", :@w, :dynamic]])
        expect(own_writes("Other.class_eval { self::E.attr_writer :w }\n"))
          .to eq([[:own_write_type, "Other::E", :@w, :dynamic]])
        expect(own_writes("x.attr_writer :w\n")).to eq([])
      end

      it "visits a `class <<` header with the class around it" do
        expect(own_writes("class C; def m; class << self; attr_writer :w; end; end; end\n"))
          .to eq([[:ivar_set_class, "C"]])
      end
    end
  end

  # Issue #617 — a constant compound write reads a name the census sees bound as `Dynamic[top]`, and a name a file
  # writes only through `||=` is the memoization idiom rather than a binding, so it carries its own descriptor.
  describe "the publication census's memo descriptor" do
    def census(source) = described_class.send(:constant_writes_for_file, parse(source))

    it "files a name written only through `||=` as a memo, bare or as a path, however often" do
      expect(census(<<~RUBY)).to eq("A" => :memo, "Conf::B" => :memo)
        def a = (A ||= {})
        def again = (A ||= {})
        def b = (Conf::B ||= [])
      RUBY
    end

    it "files every other form, and a memo the same file also writes another way, as unpublishable" do
      writes = census(<<~RUBY)
        A ||= 1
        A += 1
        B &&= 1
        C ||= 1
        C = 2
        D = 1
        D ||= 2
        E += 1
      RUBY
      expect(writes).to eq(%w[A B C D E].to_h { |name| [name, :unpublishable] })
    end
  end

  describe ".rebound_block_self" do
    define_method(:rebound) do |source, prefix = [], *rest|
      described_class.rebound_block_self(statement(source), prefix, *rest)
    end

    it "answers nil for what opens no block that rebinds `self`" do
      ["x = 1", "foo", "foo { }", "foo(&blk)", "K.tap { }", "K.class_eval(&b)", "K.class_eval('x')"].each do |source|
        expect(rebound(source)).to be_nil, source
      end
    end

    it "answers the opaque self for a `define_method` block and for a factory block nothing names" do
      blocks = ["define_method(:a) { }", "Class.new { }", "Module.new { }", "Struct.new(:a) { }", "Data.define(:a) { }"]

      blocks.each { |source| expect(rebound(source)).to eq(opaque), source }
    end

    it "answers the name its caller gives a factory block's class, and that for no other block" do
      expect(rebound("Class.new { }", [], nil, "K")).to eq("K")
      expect(rebound("define_method(:a) { }", [], nil, "K")).to eq(opaque)
      expect(rebound("R.class_eval { }", [], nil, "K")).to eq("R")
    end

    it "names the receiver of each eval-family call, as written" do
      %w[class_eval module_eval instance_eval class_exec instance_exec].each do |name|
        expect(rebound("K.#{name} { }")).to eq("K"), name
      end
      expect(rebound("A::B.class_eval { }", %w[M])).to eq("A::B")
      expect(rebound("::A.class_eval { }", %w[M])).to eq("A")
    end

    it "answers nil for a receiverless or `self.` eval, which leaves `self` where it was" do
      expect(rebound("class_eval { }", %w[M])).to be_nil
      expect(rebound("self.class_eval { }", %w[M])).to be_nil
    end

    it "answers the opaque self for a receiver that is no static path" do
      expect(rebound("x.class_eval { }")).to eq(opaque)
      expect(rebound("foo.bar::Baz.class_eval { }")).to eq(opaque)
    end

    it "anchors a `self::` receiver at the enclosing self: the prefix, or the owner the walk carries" do
      expect(rebound("self::X.class_eval { }", %w[M])).to eq("M::X")
      expect(rebound("self::X.class_eval { }")).to eq("X")
      expect(rebound("self::X.class_eval { }", %w[M], nil, nil, "A::B")).to eq("A::B::X")
      expect(rebound("self::X.class_eval { }", %w[M], nil, nil, "Object")).to eq("X")
      expect(rebound("self::X.class_eval { }", %w[M], nil, nil, opaque)).to eq(opaque)
    end

    it "resolves a receiver through the nesting when it is handed a scope, as a path write's namespace is" do
      scope = knowing("Admin::Holder")

      expect(rebound("Holder.class_eval { }", %w[Admin], scope)).to eq("Admin::Holder")
      expect(rebound("Holder.class_eval { }", %w[Admin], empty)).to eq("Holder")
      expect(rebound("Holder.class_eval { }", %w[Admin])).to eq("Holder")
      expect(rebound("Holder.class_eval { }", [], scope)).to eq("Holder")
      expect(rebound("::Holder.class_eval { }", %w[Admin], scope)).to eq("Holder")
    end
  end

  describe ".dynamic_target_key" do
    it "spells the wildcard key of a last segment" do
      expect(described_class.dynamic_target_key("LIMIT")).to eq("*::LIMIT")
      expect(described_class.dynamic_target_key("LIMIT")).to start_with(indexer::DYNAMIC_TARGET_PREFIX)
    end
  end

  # What another file of `lib/` calls: `scope_indexer.rb` each of the four, `constant_ivar_value.rb` and
  # `pre_eval_constants.rb` the typed walk's entry, `shared_walk_tables.rb` the block rule. A fifth name here is a
  # new way into the module. The one public constant is the descriptor of a write that publishes no value.
  it "exposes the four functions another file calls, and the unpublishable descriptor" do
    expect(described_class.singleton_methods(false).sort)
      .to eq(%i[build_in_source_constants constant_write_census dynamic_target_key rebound_block_self])
    expect(described_class.constants(false)).to eq([:CONSTANT_UNPUBLISHABLE])
    expect(described_class::CONSTANT_UNPUBLISHABLE).to eq(:unpublishable)
  end

  it "leaves none of its 40 functions and none of its four constants on ScopeIndexer" do
    functions = described_class.private_instance_methods(false)
    constants = %i[CONSTANT_UNPUBLISHABLE OPAQUE_SELF_BLOCK_CALLS OBJECT_OWNER CensusTables]

    expect(functions.size).to eq(40)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
    expect(constants.select { |name| indexer.const_defined?(name, false) }).to eq([])
    expect(constants.reject { |name| described_class.const_defined?(name, false) }).to eq([])
  end

  # The #3318 cut-off counts the functions a moved cluster calls back in what stays, and allows four. This one calls
  # two: the scope a census types a body's rvalues under, and the chain it answers `Module.nesting` with.
  it "calls two functions of the indexer, at one site each" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/constant_tables.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == "ScopeIndexer"
    end

    expect(calls).to eq(%i[census_body_scope census_nesting])
  end

  describe "its callers" do
    it "is the in-source table and the local-name tables `ScopeIndexer.index` seeds" do
      program = parse("class C; X = 1; self::Y = :s; end\nLIMIT = 3\n")
      published = empty.with_discovery(empty.discovery.with(published_constant_names: Set["LIMIT"]))
      scope = indexer.index(program, default_scope: published)[program]

      expect(scope.in_source_constants.transform_values(&:describe))
        .to eq("C::X" => "1", "C::Y" => ":s", "LIMIT" => "3")
      expect(scope.local_constant_names).to eq(Set["LIMIT"])
    end

    it "is the census and the wildcard key the cross-file fold files" do
      Dir.mktmpdir do |dir|
        writer = File.join(dir, "writer.rb")
        dynamic = File.join(dir, "dynamic.rb")
        File.write(writer, "module App; LIMIT = 7; end\n")
        File.write(dynamic, "k::LIMIT = 8\n")
        index = indexer.discovered_def_index_for_paths([writer, dynamic])

        expect(index[:constant_writes])
          .to eq("App::LIMIT" => { writer => [7] }, "*::LIMIT" => { dynamic => :unpublishable })
        expect(index[:constant_values]).to eq({})
        expect(index[:constant_sources]).to eq("App::LIMIT" => Set[writer, dynamic], "*::LIMIT" => Set[dynamic])
        expect(indexer.discovered_def_index_for_paths([writer])[:constant_values].transform_values(&:describe))
          .to eq("App::LIMIT" => "7")
      end
    end

    # An `include` in a block that rebinds `self` is the receiver's, or nobody's where the block's self reaches no
    # name; in an ordinary block it is the enclosing class's, and one of the names its header nesting is keyed by.
    it "is the block rule the mixin tables and the header nestings ask" do
      source = "class Outer < Base; Class.new { include T }; Other.class_eval { include T }; " \
               "x.class_eval { include T }; each { include U }; end\n"

      expect(indexer::MixinTables.send(:build_discovered_includes, parse(source)))
        .to eq("Other" => ["T"], "Outer" => ["U"])
      _supers, nestings = indexer::SharedWalkTables.send(:build_superclass_tables, parse(source))
      expect(nestings.fetch("Outer").keys).to eq([nil, "Base", "U"])
    end

    it "is the typed walk `PreEvalConstants` and `ConstantIvarValue` run" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "boot.rb")
        File.write(path, "module Conf; TIMEOUT = 30; end\n")
        constants = Rigor::Inference::PreEvalConstants.collect(paths: [path], scope_builder: ->(_path) { empty })

        expect(constants.transform_values(&:describe)).to eq("Conf::TIMEOUT" => "Integer")
      end
      program = parse("class C; TABLE = :t; end\n")
      value = indexer::ConstantIvarValue.new(program, empty)

      expect(value.send(:constants).transform_values(&:describe)).to eq("C::TABLE" => ":t")
    end
  end

  # The module reads `OPAQUE_SELF`, `RECEIVER_EVAL_CALLS`, `CONSTANT_MEMO` and `DYNAMIC_TARGET_PREFIX` through
  # `ScopeIndexer`'s own names and calls two of its functions, all of which `scope_indexer.rb` defines; and it names
  # `InEffectRefinements` without requiring its file, which does not load before `scope.rb`. The file requires what
  # else it names, and until the indexer has loaded only a call that reaches none of the seven answers.
  def alone_probe
    <<~RUBY
      require "rigor/inference/scope_indexer/constant_tables"
      indexer = Rigor::Inference::ScopeIndexer
      tables = indexer::ConstantTables
      inference = Rigor::Inference
      named = [defined?(inference::DeclarationWalk::Rules), defined?(indexer::EmptySeed),
               defined?(inference::GlobalWriteCensus), defined?(inference::ReceiverWriterCall),
               defined?(Rigor::Analysis::DependencyRecorder), defined?(Rigor::Type::Combinator),
               defined?(Rigor::Source::ConstantPath), Prism::ProgramNode.method_defined?(:rigor_each_child)]
      absent = [defined?(inference::InEffectRefinements), defined?(Rigor::Scope)]
      statement = ->(source) { Prism.parse(source).value.statements.body.first }
      failure = lambda do |&call|
        call.call
      rescue NameError => e
        [e.class.name, e.name]
      end
      rule = ->(source) { failure.call { tables.rebound_block_self(statement.call(source), []) } }
      scope = Struct.new(:lexical_nesting) { def type_of(_node) = Rigor::Type::Combinator.constant_of(1) }.new(nil)
      typed = ->(source) { failure.call { tables.build_in_source_constants(Prism.parse(source).value, scope).keys } }
      answers = [failure.call { tables.constant_write_census(Prism.parse("X = 1").value) },
                 failure.call { tables.dynamic_target_key("A") },
                 rule.call("x = 1"), rule.call("define_method(:a) { }"), rule.call("K.class_eval { }"),
                 typed.call("X = 1; A::B = 2"), typed.call("class C; X = 1; end"), typed.call("self::X = 1"),
                 tables::CONSTANT_UNPUBLISHABLE]
      print [indexer.respond_to?(:index), named, absent, answers].inspect
    RUBY
  end

  it "loads without the indexer, with what it names, and answers only what needs nothing of the indexer" do
    lib = File.join(DeclarationFactSources::REPO_ROOT, "lib")
    out, err, status = RubyRun.capture("-I", lib, "-e", alone_probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, ["constant", "constant", "constant", "constant", "constant", "constant", "constant", ' \
                      'true], [nil, nil], [["NameError", :InEffectRefinements], ' \
                      '["NameError", :DYNAMIC_TARGET_PREFIX], nil, ["NameError", :OPAQUE_SELF], ' \
                      '["NameError", :RECEIVER_EVAL_CALLS], ["X", "A::B"], ["NameError", :OPAQUE_SELF], ' \
                      '["X"], :unpublishable]]')
  end
end
