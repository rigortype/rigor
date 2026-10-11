# frozen_string_literal: true

# Issue #1664 (ADR-121 WD2–WD4) — a call through an in-effect Ruby refinement is typed from the winning refine body,
# not from the method the refinement replaces.
#
# Every precedence expectation below is the answer CRuby gives for the same source (probed on Ruby 4.0.5).

require "spec_helper"

RSpec.describe "Typing calls through Ruby refinements (#1664)", type: :runner do
  let(:sym_syntax) do
    <<~RUBY
      module SymSyntax
        refine Symbol do
          def [](other) = "\#{self}.\#{other}"
          def shout = to_s.upcase
        end
      end
    RUBY
  end

  let(:later_definers) do
    <<~RUBY
      module DM
        refine(String) do
          def center(a) = 1
          define_method(:center) { |a| "dm" }
        end
      end
      module AM
        refine(Symbol) do
          def center(a) = 1
          alias_method :center, :to_s
        end
      end
      module AL
        refine(Integer) do
          def c3 = 1
          define_method(:c3) { "s" }
          alias center c3
        end
      end
      module AT
        refine(Float) do
          def center = 1
          attr_reader :center
        end
      end
      using DM
      using AM
      using AL
      using AT
      p "x".center(1).upcase
      p :x.center.upcase
      p 1.center.upcase
      p 1.5.center.inspect
      Rigor.dump_type("x".center(1))
      Rigor.dump_type(:x.center)
      Rigor.dump_type(1.center)
      Rigor.dump_type(1.5.center)
    RUBY
  end

  # `[rule, line, message]` for every diagnostic in `app.rb`.
  def rows(source, files: {})
    result = analyze(files: files.merge("app.rb" => source))
    result.diagnostics.select { |d| d.path.to_s.end_with?("app.rb") }
          .map { |d| [d.qualified_rule, d.line, d.message] }
  end

  # The `dump_type` messages in `app.rb`, in line order.
  def dumps(source, files: {})
    rows(source, files: files).select { |rule, _line, _message| rule == "dump.type" }
                              .map { |_rule, _line, message| message.delete_prefix("dump_type: ") }
  end

  it "types the issue's repro from the refine body, and keeps the core signature without the `using`" do
    expect(dumps(<<~RUBY, files: { "sym_syntax.rb" => sym_syntax })).to eq(%w[String? String String])
      Rigor.dump_type(:authors[:age])
      using SymSyntax
      Rigor.dump_type(:authors[:age])
      Rigor.dump_type(:a.shout)
    RUBY
  end

  it "types a refinement declared in the same file" do
    expect(dumps(<<~RUBY)).to eq(%w[String])
      #{sym_syntax}
      using SymSyntax
      Rigor.dump_type(:authors[:age])
    RUBY
  end

  it "does not fold a refined core method, and answers the later of two `using`s" do
    expect(dumps(<<~RUBY)).to eq(%w[non-negative-int :up])
      module Sized
        refine(String) { def upcase = size }
      end
      module Symbolic
        refine(String) { def upcase = :up }
      end
      using Sized
      Rigor.dump_type("a".upcase)
      using Symbolic
      Rigor.dump_type("a".upcase)
    RUBY
  end

  it "lets a subclass's own method beat a refinement of its superclass" do
    expect(dumps(<<~RUBY)).to eq(["1", %("refined")])
      class Base; def m = "base"; end
      class Child < Base; def m = 1; end
      module RefineBase
        refine(Base) { def m = :refined }
      end
      using RefineBase
      Rigor.dump_type(Child.new.m)
      Rigor.dump_type(Base.new.m.to_s)
    RUBY
  end

  it "lets a refinement of a class beat a module prepended to it, and decides a refined module where it sits" do
    expect(dumps(<<~RUBY)).to eq(%w[:refined :refined])
      module P
        def m = "p"
        def q = "p"
      end
      class C
        prepend P
        def m = "c"
      end
      class D
        prepend P
        def q = "d"
      end
      module RefineC
        refine(C) { def m = :refined }
        refine(P) { def q = :refined }
      end
      using RefineC
      Rigor.dump_type(C.new.m)
      Rigor.dump_type(D.new.q)
    RUBY
  end

  # Review of #1747: a body another file wrote runs with its own refinements in effect; Ruby prints `true` and `21.0`.
  it "types a refine body from another file with that file's refinements in effect" do
    refinement = <<~RUBY
      module R
        refine String do
          def upcase = 42
          def twice = upcase
        end
      end
    RUBY
    expect(rows(<<~RUBY, files: { "r.rb" => refinement })).to eq([["dump.type", 3, "dump_type: 42"]])
      using R
      x = "a".twice
      Rigor.dump_type(x)
      x.even?
      x.fdiv(2)
    RUBY
  end

  # Review of #1747: Ruby prints `LOUD` and `YELL`, because the module a project reopening mixes into a core class
  # sits ahead of `Object` in the lookup. The arm declines rather than order a mixin RBS does not record.
  it "declines where the project mixes a module into a core class's ancestry" do
    expect(rows(<<~RUBY)).to eq([])
      module Loud; def shout = "loud"; end
      class String; include Loud; end
      module Yell; def yell = "yell"; end
      class Integer; prepend Yell; end
      module RO
        refine(Object) do
          def shout = 1
          def yell = 2
        end
      end
      using RO
      "a".shout.upcase
      1.yell.upcase
    RUBY
  end

  # Review of #1747: a mixin into a less derived ancestor (`Object.include`) cannot outrank a refinement of the
  # receiver's own class; Ruby prints `true`.
  it "keeps a refinement of the receiver's class winning over a project mixin into a less derived ancestor" do
    expect(rows(<<~RUBY)).to eq([["dump.type", 5, "dump_type: 42"]])
      module Helpers; def hh = 1; end
      Object.include(Helpers)
      module R; refine(String) { def upcase = 42 }; end
      using R
      Rigor.dump_type("a".upcase)
      "a".upcase.even?
    RUBY
  end

  # Review of #1747: `refine String` inside a module that declares its own `String` refines that one; Ruby prints `X`.
  it "refines the class the `refine` argument resolves to, not every name its spelling could denote" do
    expect(dumps(<<~RUBY)).to eq([%("X")])
      module M
        class String; end
        refine(String) { def upcase = 1 }
      end
      using M
      Rigor.dump_type("x".upcase)
    RUBY
  end

  it "reaches any receiver through a refinement of Object, and a project class through a refined included module" do
    expect(dumps(<<~RUBY)).to eq(%w[1 :mixed])
      module Mix; def mixed = "mix"; end
      class Base < Object; end
      class Kid < Base; include Mix; end
      module RO
        refine(Object) { def anything = 1 }
        refine(Mix) { def mixed = :mixed }
      end
      using RO
      Rigor.dump_type([1].anything)
      Rigor.dump_type(Kid.new.mixed)
    RUBY
  end

  it "types a union receiver per member" do
    expect(dumps(<<~RUBY)).to eq([%("big" | 8)])
      module Sizes
        refine(Symbol) { def size = "big" }
      end
      using Sizes
      x = [true, false].sample ? :a : 1
      Rigor.dump_type(x.size)
    RUBY
  end

  # Issue #1752. A class object is an `Object`, so its lookup (its singleton class, each superclass's, then `Class`,
  # `Module`, `Object`, `Kernel` and `BasicObject`) reaches these refinements. Ruby 4.0.5 prints `:o`, `1`, `"c"`,
  # `3.0`, `[1]`, `1` and `"Integer"`: the refine body runs with the class object as `self`.
  it "types a class object's call from a refinement of Object, Module, Class, Kernel or BasicObject" do
    expect(dumps(<<~RUBY)).to eq([":o", "1", %("c"), "3.0", "[1]", "1", "String"])
      module R
        refine(Object) { def oo = :o }
        refine(Module) { def mm = 1; def label = name }
        refine(Class) { def cc = "c" }
        refine(Kernel) { def kk = 3.0 }
        refine(BasicObject) { def bo = [1] }
      end
      class Own; end
      module Mod; end
      using R
      Rigor.dump_type(Integer.oo)
      Rigor.dump_type(String.mm)
      Rigor.dump_type(String.cc)
      Rigor.dump_type(Own.kk)
      Rigor.dump_type(Mod.bo)
      Rigor.dump_type(Comparable.mm)
      Rigor.dump_type(Integer.label)
    RUBY
  end

  # Ruby 4.0.5 prints `4` and `1`: `Integer.sqrt` and `Own.own` sit on the class objects' own singleton classes, ahead
  # of the refinement of `Object`.
  it "lets a class object's own singleton method beat a refinement of Object" do
    expect(dumps(<<~RUBY)).to eq(%w[Integer 1])
      module RS
        refine(Object) { def sqrt(a) = :o; def own = :o }
      end
      class Own; def self.own = 1; end
      using RS
      Rigor.dump_type(Integer.sqrt(16))
      Rigor.dump_type(Own.own)
    RUBY
  end

  # Ruby 4.0.5 prints `:refined`, `:own`, `:ext` and `:p_refined`. `D`'s own `def self.z` answers ahead of the module
  # it extends, but the tables record `class << self; prepend M` as an `extend` (and `E` prepends `P`, whose
  # refinement answers ahead of `E`'s own method), so with a refined module beside it on the singleton level the arm
  # cannot tell which comes first and answers `Dynamic[top]`.
  it "types a class object's call from a refinement of a module it extends" do
    expect(dumps(<<~RUBY)).to eq([":refined", "Dynamic[top]", ":ext", "Dynamic[top]"])
      module Ext; def z = :ext; def w = :ext; end
      module P; def z = :p_own; end
      class C; extend Ext; end
      class D; extend Ext; def self.z = :own; end
      class E; class << self; prepend P; end; def self.z = :e_own; end
      module RE; refine(Ext) { def z = :refined }; refine(P) { def z = :p_refined }; end
      using RE
      Rigor.dump_type(C.z)
      Rigor.dump_type(D.z)
      Rigor.dump_type(C.w)
      Rigor.dump_type(E.z)
    RUBY
  end

  # Ruby 4.0.5 prints `:o` for either member; a parameter's call stays `Dynamic[top]` with no finding.
  it "types a union of a class object and an instance per member, and leaves a Dynamic receiver alone" do
    expect(rows(<<~RUBY)).to eq([["dump.type", 4, "dump_type: :o"], ["dump.type", 5, "dump_type: Dynamic[top]"]])
      module RO; refine(Object) { def oo = :o }; end
      using RO
      x = [true, false].sample ? Integer : "s"
      Rigor.dump_type(x.oo)
      def pass(v) = Rigor.dump_type(v.oo)
    RUBY
  end

  # A constant write may have made `Point` (here `Struct.new`, whose superclass no table records and whose singleton
  # class defines `members`), so its lookup cannot be read and a refinement in effect for the name answers
  # `Dynamic[top]`; a name nothing refines keeps its type. A refinement of a singleton class records class-unknown rows,
  # which answer `Dynamic[top]` for their names. Ruby 4.0.5 prints `:o`, `[:x]`, `"Point"` and `:s`.
  it "answers Dynamic[top] for a class object whose lookup cannot be read, and for a refined singleton class" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]", "Dynamic[top]", "String", "Dynamic[top]"])
      module RO; refine(Object) { def oo = :o }; end
      module RM; refine(Module) { def members = :m }; end
      module RSC; refine(Integer.singleton_class) { def sqrt(a) = :s }; end
      Point = Struct.new(:x)
      using RO
      using RM
      using RSC
      Rigor.dump_type(Point.oo)
      Rigor.dump_type(Point.members)
      Rigor.dump_type(Point.name)
      Rigor.dump_type(Integer.sqrt(16))
    RUBY
  end

  # `Loud`, which the project extends `String` with at a position RBS does not record, answers `String.mm` ahead of the
  # refinement of `Module` (Ruby 4.0.5 prints `:loud`), so the walk past `String`'s singleton class answers
  # `Dynamic[top]`; a refinement of `Loud` itself does too, where Ruby prints `2`.
  it "answers Dynamic[top] past a singleton class the project extends" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]", "Dynamic[top]", "1"])
      module Loud; def mm = :loud; def ll = :plain; end
      class String
        extend Loud
      end
      module RM
        refine(Module) { def mm = 1 }
        refine(Loud) { def ll = 2 }
      end
      using RM
      Rigor.dump_type(String.mm)
      Rigor.dump_type(String.ll)
      Rigor.dump_type(Integer.mm)
    RUBY
  end

  it "answers Dynamic[top] for a refined name reached through send, &:name and respond_to?, with no finding" do
    expect(rows(<<~RUBY, files: { "sym_syntax.rb" => sym_syntax })).to eq(
      using SymSyntax
      Rigor.dump_type(:authors.send(:[], :age))
      Rigor.dump_type([:a].map(&:shout))
      Rigor.dump_type(:a.respond_to?(:shout))
      Rigor.dump_type(:a.respond_to?(:nope))
    RUBY
      [
        ["dump.type", 2, "dump_type: Dynamic[top]"],
        ["dump.type", 3, "dump_type: Dynamic[top]"],
        ["dump.type", 4, "dump_type: Dynamic[top]"],
        ["dump.type", 5, "dump_type: bool"]
      ]
    )
  end

  it "answers Dynamic[top] under a `using` that names no module, for a name some refinement defines" do
    expect(dumps(<<~RUBY, files: { "sym_syntax.rb" => sym_syntax })).to eq(["Dynamic[top]", %("a")])
      using Module.new { refine(Integer) { def x = 1 } }
      Rigor.dump_type(:a.shout)
      Rigor.dump_type(:a.to_s)
    RUBY
  end

  # ADR-121 WD7 (critique F2). Ruby 4.0.5 prints `43` and `4`: a module whose refinements Rigor cannot read may replace
  # any method, so every call in its `using`'s span answers `Dynamic[top]`, never the replaced method's signature.
  # Issue #1752: that includes a call on a class object (a `refine(Integer.singleton_class)` there would replace
  # `Integer.sqrt`), which fell through before class objects walked their own lookup.
  it "answers Dynamic[top] for every call under a `using` of a module from outside the analysed paths" do
    result = analyze(
      files: {
        "outside/gemref.rb" => "module GemRef; refine(String) { def center(a, b, c) = 42 }; end\n",
        "lib/app.rb" => <<~RUBY
          $LOAD_PATH.unshift(File.join(__dir__, "..", "outside"))
          require "gemref"
          using GemRef
          p "s".center(1, 2, 3).succ.times { |i| i }
          Rigor.dump_type("s".center(1, 2, 3))
          Rigor.dump_type(Integer.sqrt(16))
        RUBY
      },
      config: { "paths" => ["lib"] }
    )
    rows = result.diagnostics.map { |d| [d.qualified_rule, d.line, d.message] }

    expect(rows).to eq([["dump.type", 5, "dump_type: Dynamic[top]"], ["dump.type", 6, "dump_type: Dynamic[top]"]])
  end

  # ADR-121 WD7 (A2). Ruby 4.0.5 prints `43` and `"S"`: a refinement whose target the walk cannot name makes only the
  # names it defines `Dynamic[top]`, on any instance.
  it "answers Dynamic[top] for a name refined on a class the walk cannot name, and nothing else" do
    expect(rows(<<~RUBY)).to eq([["dump.type", 6, "dump_type: Dynamic[top]"], ["dump.type", 7, %(dump_type: "S")]])
      module M
        [String, Symbol].each { |k| refine(k) { def center(a, b, c) = 42 } }
      end
      using M
      p "s".center(1, 2, 3).succ.times { |i| i }
      Rigor.dump_type(:s.center(1, 2, 3))
      Rigor.dump_type("s".upcase)
    RUBY
  end

  # ADR-121 WD7. Ruby 4.0.5 prints `:b`, `"S"` and `2`: `import_methods` may define any name on String.
  it "answers Dynamic[top] on a class a refine body may define any name on, and keeps other classes typed" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]", "Dynamic[top]", "2"])
      module H; def b = :b; end
      module M
        refine(String) do
          def a = 1
          import_methods H
        end
      end
      using M
      Rigor.dump_type("s".b)
      Rigor.dump_type("s".upcase)
      Rigor.dump_type(1.succ)
    RUBY
  end

  # ADR-121 WD7. Ruby 4.0.5 prints `"dm"`: `app.rb` requires `other.rb` first, so its `define_method` replaces the other
  # file's `def`. The own file's bodiless definer ends the search for a body.
  it "answers Dynamic[top] where the call's own file redefines a refined name without a body" do
    other = "module M\n  refine(String) { def center(a) = 1 }\nend\n"
    expect(dumps(<<~RUBY, files: { "other.rb" => other })).to eq(["Dynamic[top]"])
      require_relative "other"
      module M
        refine(String) { define_method(:center) { |a| "dm" } }
      end
      using M
      Rigor.dump_type("x".center(1))
    RUBY
  end

  # ADR-121 WD7. Ruby 4.0.5 prints `42`: the refinement of the included `Greet` imports `H#hi`, which wins over
  # `Greet#hi` where `Greet` sits in `Foo`'s lookup.
  it "answers Dynamic[top] where an included module a refine body may define any name on sits" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
      module H; def hi = 42; end
      module Greet; def hi = "hi"; end
      class Foo; include Greet; end
      module M
        refine(Greet) { import_methods H }
      end
      using M
      Rigor.dump_type(Foo.new.hi)
    RUBY
  end

  # ADR-121 WD7. Ruby 4.0.5 prints `42`: past `String`, whose project mixin RBS does not order, the refinement of
  # `Object` imports `H#itself`, which wins over `Kernel#itself`.
  it "answers Dynamic[top] past a mixed level when a later level's refine body may define any name" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
      module H; def itself = 42; end
      module Loud; end
      class String; include Loud; end
      module RO
        refine(Object) { import_methods H }
      end
      using RO
      Rigor.dump_type("a".itself)
    RUBY
  end

  # ADR-121 WD7 (A1). In this file Ruby 4.0.5 prints `:inner` and raises `ArgumentError`, but with `Foo::Bar` declared
  # in a file required after this one the top-level `Bar` wins (critique F1), so neither call is typed from a body.
  it "answers Dynamic[top] where two declared candidates of a `using` could each be the module" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]", "Dynamic[top]"])
      module Bar; refine(String) { def center(a, b, c) = :bar }; end
      module Foo
        module Bar; refine(String) { def upcase = :inner }; end
        using Bar
        Rigor.dump_type("x".upcase)
        Rigor.dump_type("x".center(1, 2, 3))
      end
    RUBY
  end

  # ADR-121 WD7. `M.module_eval { refine … }` inside `module L` runs on one module, `L::M` here, but the walk charges
  # every name `M` can denote there, so the body may be the top-level `M`'s or not and types from neither. Ruby 4.0.5
  # prints `"  X  "`: the refinement is `L::M`'s, and under `using M` the call is String#center.
  it "answers Dynamic[top] with no finding for a body an eval on a constant may have run on another module" do
    expect(rows(<<~RUBY)).to eq([["dump.type", 10, "dump_type: Dynamic[top]"]])
      module M
        refine(Integer) { def twice = self * 2 }
      end
      module L
        module M; end
        M.module_eval { refine(String) { def center(width) = 42 } }
      end
      using M
      p "x".center(5).upcase
      Rigor.dump_type("x".center(5))
    RUBY
  end

  # The same body may replace an earlier `def` of either name: Ruby 4.0.5 prints `42` twice, the eval on `N` running on
  # the `L::N` this file declares and the one on `M` on the top-level `M`, so neither earlier `def` answers.
  it "answers Dynamic[top] where an eval body on a constant may replace an earlier def under any of its names" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]", "Dynamic[top]"])
      module M
        refine(String) { def center(width) = :top }
      end
      module L
        module N; refine(String) { def ljust(width) = :inner }; end
        N.module_eval { refine(String) { def ljust(width) = 42 } }
        M.module_eval { refine(String) { def center(width) = 42 } }
      end
      using L::N
      Rigor.dump_type("x".ljust(5))
      using M
      Rigor.dump_type("x".center(5))
    RUBY
  end

  # ADR-121 WD7 (issue #1799). Ruby 4.0.5 prints `42` and `:dm`: an alias of a body's `def` types from that `def`;
  # a `define_method` has no `def` to type, so `Dynamic[top]`, never String#rjust's signature.
  it "types an alias from the aliased def and a define_method as Dynamic[top]" do
    expect(dumps(<<~RUBY)).to eq(["42", "Dynamic[top]"])
      module M
        refine(String) do
          def c3(a, b, c) = 42
          alias_method :center, :c3
          define_method(:rjust) { |a, b, c| :dm }
        end
      end
      using M
      Rigor.dump_type("x".center(1, 2, 3))
      Rigor.dump_type("x".rjust(1, 2, 3))
    RUBY
  end

  # ADR-121 WD7 — a later definer replaces an earlier `def` of the name. Ruby 4.0.5 prints `"DM"`, `"X"`, `"S"` and
  # `"nil"`: the `define_method`, the alias of `Symbol#to_s`, the alias of a `define_method` and the `attr_reader`
  # are what runs, and none has a `def` to type.
  it "answers Dynamic[top] for a name a later definer with no def replaced" do
    expect(rows(later_definers)).to eq(Array.new(4) { |i| ["dump.type", 34 + i, "dump_type: Dynamic[top]"] })
  end

  it "types a refine body's `super` as Dynamic[top] with no finding when another refinement is in effect there" do
    expect(rows(<<~RUBY)).to eq([["dump.type", 6, "dump_type: Dynamic[top]"]])
      module First
        refine(String) { def sup = 1 }
      end
      module Second
        using First
        refine(String) { def sup = Rigor.dump_type(super) }
      end
    RUBY
  end
end
