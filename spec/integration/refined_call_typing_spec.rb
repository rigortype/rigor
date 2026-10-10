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
    expect(dumps(<<~RUBY)).to eq(%w[1 "refined"])
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
    expect(dumps(<<~RUBY, files: { "sym_syntax.rb" => sym_syntax })).to eq(%w[Dynamic[top] "a"])
      using Module.new { refine(Integer) { def x = 1 } }
      Rigor.dump_type(:a.shout)
      Rigor.dump_type(:a.to_s)
    RUBY
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
