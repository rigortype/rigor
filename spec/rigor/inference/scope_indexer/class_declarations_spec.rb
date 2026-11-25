# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (U1) — `ScopeIndexer::ClassDeclarations` is the cross-file class-declaration walk of one file. The
# examples hand `collect_class_decls` a parsed snippet with the prefix, accumulator and candidate table a caller in
# `scope_indexer.rb` threads, and read the two tables back: no index is built and no scope evaluated, so the walk
# alone decides each row. The examples that pin the same table through `ScopeIndexer.discovered_classes_for_paths`
# and through a run stay where they are, since they also read what the fold makes of it.
RSpec.describe Rigor::Inference::ScopeIndexer::ClassDeclarations do
  def singleton(name) = Rigor::Type::Combinator.singleton_of(name)

  # The accumulator and the compact-header candidates after the walk over `source`.
  def walk(source, prefix: [], self_prefix: nil, singleton_cref: false, seed: {})
    accumulator = seed.dup
    compacts = {}
    described_class.collect_class_decls(Prism.parse(source).value, prefix, accumulator, compacts, self_prefix,
                                        singleton_cref: singleton_cref)
    [accumulator, compacts]
  end

  def declared(source, **) = walk(source, **).first.transform_values(&:describe)

  def names(source, **) = walk(source, **).first.keys

  describe "a class or module header" do
    it "registers each declaration under its qualified name, a nested one under the header around it" do
      accumulator, = walk("module Foo; class Bar; end; end\nclass Baz < Base; end\n")

      expect(accumulator).to eq({ "Foo" => singleton("Foo"), "Foo::Bar" => singleton("Foo::Bar"),
                                  "Baz" => singleton("Baz") })
    end

    it "qualifies a compact header under the prefix around it, and starts again at a rooted one" do
      expect(names("module A; class B::C; end; class ::D; class E; end; end; end\n"))
        .to eq(%w[A A::B::C D D::E])
    end

    it "starts from the prefix it is handed" do
      expect(names("class X; end\n", prefix: ["Outer"])).to eq(["Outer::X"])
    end

    it "finds a declaration wherever it is written: a value, an argument, a branch, a block" do
      source = <<~RUBY
        x = (class InValue; self; end)
        foo(class InArg; self; end)
        if c then class InBranch; end end
        [1].each { class InBlock; end }
      RUBY

      expect(names(source)).to eq(%w[InValue InArg InBranch InBlock])
    end

    it "anchors a `self::` header on the rebound self it is handed, and on the prefix when it is handed none" do
      expect(names("class self::S; end\n", prefix: ["C"], self_prefix: ["X"])).to eq(["X::S"])
      expect(names("class self::S; end\n", prefix: ["C"])).to eq(["C::S"])
    end

    it "hands the body no rebound self: a `self::` header inside it is the header's own" do
      expect(names("class self::A; class self::B; end; end\n", self_prefix: ["X"])).to eq(%w[X::A X::A::B])
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

      expect(names(source)).to eq(%w[C Other::Leaf Rooted Rooted::In])
    end

    it "walks the expression in the enclosing context" do
      expect(names("class C; class << (class D; self; end); end; end\n")).to eq(%w[C C::D])
    end

    it "declines a `self::` header, written there or in an eval block of its own self" do
      expect(names("class C; class << self; class self::S; end; end; end\n")).to eq(["C"])
      expect(names("class C; class << self; class_eval { class self::D; end }; end; end\n")).to eq(["C"])
    end

    it "keeps its cref below an eval block: a bare header there is declined, a `self::` one is the receiver's" do
      expect(names("class C; class << self; X.class_eval { class E; end; class self::D; end }; end; end\n"))
        .to eq(%w[C X::D])
    end

    it "declines an eval call's `self::` receiver, there and below a bare header" do
      expect(names("class C; class << self; self::T.class_eval { class self::D; end }; end; end\n")).to eq(["C"])
      expect(names("class C; class << self; class Hidden; self::T.class_eval { class self::D; end }; end; end; end\n"))
        .to eq(["C"])
    end
  end

  describe "an eval-family block" do
    it "anchors a `self::` header on the receiver and keeps a bare header lexical" do
      expect(names("module M; X.class_eval { class self::D; end; class E; end }; end\n")).to eq(%w[M X::D M::E])
    end

    it "does so for each call that rebinds self, and for no other call with a block" do
      %w[class_eval module_eval class_exec module_exec instance_eval instance_exec].each do |call|
        expect(names("X.#{call} { class self::D; end }\n")).to eq(["X::D"]), call
      end
      expect(names("X.tap { class self::D; end }\n")).to eq(["D"])
    end

    it "keeps the enclosing self for a bare receiver, and declines a `self::` header under a receiver it cannot name" do
      expect(names("module M; class_eval { class self::D; end }; end\n")).to eq(%w[M M::D])
      expect(names("X.class_eval { class_eval { class self::D; end } }\n")).to eq(["X::D"])
      expect(names("module M; foo.class_eval { class self::D; end; class E; end }; end\n")).to eq(%w[M M::E])
    end

    it "anchors a `self::` receiver on the class around the call" do
      expect(names("class C; self::T.class_eval { class self::D; end }; end\n")).to eq(%w[C C::T::D])
    end

    it "walks the receiver and the arguments in the enclosing context" do
      expect(names("(class Recv; self; end).class_eval(class Arg; self; end) { }\n")).to eq(%w[Recv Arg])
      expect(names("X.class_eval { foo.class_eval((class self::InArg; self; end)) { } }\n")).to eq(["X::InArg"])
    end

    it "walks a call whose block is an argument as any other node" do
      expect(names("X.class_eval(&(class InBlockArg; self; end))\n")).to eq(["InBlockArg"])
    end
  end

  describe "a constant write that creates a class" do
    it "records each factory form under the constant's qualified name, in each spelling of the write" do
      source = <<~RUBY
        module N
          K = Class.new
          M = Module.new
          P = Data.define(:x)
          S = Struct.new(:a)
          O ||= Class.new
          A::B = Class.new
          A::C ||= Class.new
        end
      RUBY

      expect(declared(source)).to eq(
        "N" => "singleton(N)", "N::K" => "singleton(N::K)", "N::M" => "singleton(N::M)",
        "N::P" => "singleton(N::P)", "N::S" => "singleton(N::S)", "N::O" => "singleton(N::O)",
        "N::A::B" => "singleton(N::A::B)", "N::A::C" => "singleton(N::A::C)"
      )
    end

    it "records nothing for a write of anything else" do
      expect(declared("K = 1\nL = foo.new\nN = Class.new.new\n")).to eq({})
    end

    it "borrows the superclass's name for a block-less `Class.new(Super)` alone" do
      expect(declared("K = Class.new(Base)\nL = Class.new(Base) { }\n"))
        .to eq("K" => "singleton(Base)", "L" => "singleton(L)")
    end

    it "qualifies the borrowed name under the innermost enclosing prefix that declares it, else as written" do
      nested = <<~RUBY
        module N
          class Error; end
          module O
            class Error; end
            E = Class.new(Error)
          end
          F = Class.new(Error)
          G = Class.new(Other)
        end
        H = Class.new(Error)
      RUBY

      expect(declared(nested).slice("N::O::E", "N::F", "N::G", "H")).to eq(
        "N::O::E" => "singleton(N::O::Error)", "N::F" => "singleton(N::Error)", "N::G" => "singleton(Other)",
        "H" => "singleton(Error)"
      )
    end

    it "reads the names another file declared from the accumulator it is handed" do
      expect(declared("module N; module O; E = Class.new(Error); end; end\n",
                      seed: { "N::Error" => singleton("N::Error") }))
        .to include("N::O::E" => "singleton(N::Error)")
    end

    it "leaves the prefix it searched as it was: a declaration after the write keeps its name" do
      source = "module N; module O; E = Class.new(Error); class After; end; end; end\n"

      expect(names(source, seed: { "N::Error" => singleton("N::Error") })).to include("N::O::After")
    end

    it "keeps the constant's own name when the superclass argument is no constant" do
      expect(declared("module N; E = Class.new(foo); end\n")).to include("N::E" => "singleton(N::E)")
    end

    it "gives the block the class the write names as its self, and leaves its cref lexical" do
      source = "module W; K = Class.new { class self::Inner; end; class Lexical; end }; end\n"

      expect(names(source)).to eq(%w[W W::K W::K::Inner W::Lexical])
    end

    it "inside an eval block, anchors a `self::` target and its block on the receiver, and keeps a bare one lexical" do
      expect(names("X.class_eval { self::S = Class.new { class self::I; end }; T = Class.new }\n"))
        .to eq(%w[X::S X::S::I T])
    end

    it "walks the factory call's receiver and arguments in the enclosing context" do
      expect(names("K = Class.new((class InArg; self; end)) { }\n")).to eq(%w[K InArg])
    end

    it "records no write whose target names nothing, and gives its block a self nothing names" do
      expect(names("foo::K = Class.new { class self::I; end }\n")).to eq([])
      expect(names("foo.class_eval { self::S = Class.new }\n")).to eq([])
    end

    it "under `class <<`, records a rooted path write alone, and anchors its block there" do
      source = <<~RUBY
        class C
          class << self
            K = Class.new { class self::I; end }
            ::R = Class.new { class self::J; end; class Bare; end }
          end
        end
      RUBY

      expect(names(source)).to eq(%w[C R R::J])
    end
  end

  describe "the compact-header candidates" do
    it "records a compact header inside a namespace: the namespace it needs and the name it falls through to" do
      _, compacts = walk("module Wrap; class Outer::Leaf; end; end\nmodule A; module B; class C::D::E; end; end; end\n")

      expect(compacts).to eq("Wrap::Outer::Leaf" => ["Wrap::Outer", "Outer::Leaf"],
                             "A::B::C::D::E" => ["A::B::C", "C::D::E"])
    end

    it "records none at the top level, for a rooted header, or for a header whose path renders one segment" do
      expect(walk("class Outer::Leaf; end\n").last).to eq({})
      expect(walk("module Wrap; class ::Outer::Leaf; end; end\n").last).to eq({})
      expect(walk("module Wrap; class Leaf; end; class self::S; end; end\n").last).to eq({})
    end

    it "records the declarations alone when it is handed no table for them" do
      accumulator = {}
      described_class.collect_class_decls(Prism.parse("module Wrap; class Outer::Leaf; end; end\n").value, [],
                                          accumulator)

      expect(accumulator.keys).to eq(%w[Wrap Wrap::Outer::Leaf])
    end
  end

  it "answers nil for what is no node, and records nothing" do
    accumulator = {}

    expect(described_class.collect_class_decls(nil, [], accumulator)).to be_nil
    expect(accumulator).to eq({})
  end

  it "exposes the walk alone, and no constant of its own" do
    expect(described_class.singleton_methods(false)).to eq([:collect_class_decls])
    expect(described_class.constants).to be_empty
  end

  it "leaves none of its 8 functions on ScopeIndexer, public or private" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(8)
    expect(functions.select { |name| Rigor::Inference::ScopeIndexer.respond_to?(name, true) }).to eq([])
  end

  # The module reads `EMPTY_PREFIX` and `RECEIVER_EVAL_CALLS` through `ScopeIndexer`'s own names, which
  # `scope_indexer.rb` binds: the file requires what else it names and answers until a walk reaches one of the two.
  it "loads without the indexer, and answers until it reads one of the indexer's two lists" do
    probe = <<~RUBY
      require "rigor/inference/scope_indexer/class_declarations"
      walk = Rigor::Inference::ScopeIndexer::ClassDeclarations
      answers = ["module A; class B; end; end; K = Class.new(B)", "class C; class << self; D = 1; end; end",
                 "tap { }"].map do |source|
        walk.collect_class_decls(Prism.parse(source).value, [], table = {})
        table.transform_values(&:describe)
      rescue NameError => e
        e.name
      end
      print [Rigor::Inference::ScopeIndexer.respond_to?(:index), *answers].inspect
    RUBY
    out, err, status = RubyRun.capture("-I", File.join(DeclarationFactSources::REPO_ROOT, "lib"), "-e", probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, {"A" => "singleton(A)", "A::B" => "singleton(A::B)", "K" => "singleton(B)"}, ' \
                      ":EMPTY_PREFIX, :RECEIVER_EVAL_CALLS]")
  end
end
