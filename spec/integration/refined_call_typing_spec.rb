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
  # any instance method, so every instance call in its `using`'s span answers `Dynamic[top]`, never the replaced
  # method's signature; a class object falls through.
  it "answers Dynamic[top] for every instance call under a `using` of a module from outside the analysed paths" do
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

    expect(rows).to eq([["dump.type", 5, "dump_type: Dynamic[top]"], ["dump.type", 6, "dump_type: Integer"]])
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
