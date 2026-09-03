# frozen_string_literal: true

require "spec_helper"

# ADR-64 — the non-nil channel of `call.argument-type-mismatch`. The nil channel ([nil_argument_mismatch_spec]) fires on
# a pure-`nil` argument every overload rejects; this channel extends that to a non-nil argument that types to a single
# concrete, RBS-known class no overload admits — on a *non-coerce* method. The coerce-dispatch operators (`+ - * / < …`)
# are excluded because a user type may rescue a non-`Numeric` argument via `coerce` (`5 + Money.new`), which `nil` can
# never do. Acceptance is decided on the RBS parameter type so the `int` / `string` interface-aliases the translator
# degrades are resolved.
RSpec.describe "non-nil argument-type-mismatch (ADR-64)" do
  def diagnostics_for(source)
    runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
    guarded_run_source(runner, source: source, path: "mem.rb").diagnostics
  end

  def arg_mismatches(source)
    diagnostics_for(source).select { |d| d.rule == "call.argument-type-mismatch" }.map(&:message)
  end

  it "fires when a single-concrete-class arg is rejected by every overload (interface-alias param)" do
    # Array#fetch is multi-overload; its index param is `int` (Integer | _ToInt). A String is neither an Integer nor
    # `_ToInt` (no #to_int) → TypeError at runtime.
    expect(arg_mismatches("a = [1, 2, 3]\na.fetch(\"x\")\n"))
      .to include(a_string_matching(/`fetch' on Array.*expected int.*got "x"/))
    # A Symbol likewise has no #to_int.
    expect(arg_mismatches("a = [1, 2, 3]\na.fetch(:sym)\n"))
      .to include(a_string_matching(/`fetch' on Array.*got :sym/))
  end

  it "resolves the interface so a class that DOES implement it stays clean" do
    # Float has #to_int, so `_ToInt` admits it — `[1,2,3].fetch(2.0)` is valid (2.0.to_int → 2). The interface
    # resolution must accept it.
    expect(arg_mismatches("a = [1, 2, 3]\na.fetch(2.0)\n")).to be_empty
  end

  it "excludes the coerce-dispatch operators (a non-Numeric arg may coerce)" do
    # 5 * "y" / 5 + "y" raise at runtime, but the rule cannot know a user type would not define #coerce, so the
    # multi-overload arithmetic operators (`Integer#+` / `#*` each have four numeric overloads) are excluded. The
    # single-overload comparison operators (`Integer#< : (Numeric) -> bool`) are governed by the pre-existing
    # per-overload acceptance check, not this multi-overload channel.
    expect(arg_mismatches("x = 5\nx * \"y\"\n")).to be_empty
    expect(arg_mismatches("x = 5\nx + \"y\"\n")).to be_empty
    expect(arg_mismatches("x = 5\nx - \"y\"\n")).to be_empty
  end

  it "stays clean when an overload accepts the argument" do
    expect(arg_mismatches("a = [1, 2, 3]\na.fetch(0)\n")).to be_empty
    expect(arg_mismatches("x = 5\nx + 2.0\n")).to be_empty
  end

  it "does not fire across an overload arity divergence" do
    # `fetch(0, "default")`: the second positional has no matching param in the single-arg overload, so the wrong-arity
    # rule owns it, not this one.
    expect(arg_mismatches("a = [1, 2, 3]\na.fetch(0, \"default\")\n")).to be_empty
  end

  it "skips a non-RBS project class argument (its conversion protocol is invisible)" do
    expect(arg_mismatches("class Conv\n  def to_int = 2\nend\na = [1, 2, 3]\na.fetch(Conv.new)\n")).to be_empty
  end

  it "defers a union argument (WD3 — single concrete class only)" do
    # `x` is `String | nil` at the call site; a union arg is left to the union-receiver story, like the nil channel's
    # pure-nil restriction.
    expect(arg_mismatches("def f(flag)\n  x = \"s\" if flag\n  [1, 2, 3].fetch(x)\nend\n")).to be_empty
  end

  it "leaves valid real code clean" do
    source = <<~RUBY
      a = [1, 2, 3]
      a.fetch(0)
      a.fetch(1, "default")
      n = 5
      n + 2
      n < 10
    RUBY
    expect(diagnostics_for(source).select(&:error?)).to be_empty
  end

  describe "Class.new with struct/data factory superclass (#634)" do
    it "accepts Struct.new, Data.define, and Class.new as Class superclass arguments" do
      expect(arg_mismatches("Class.new(Struct.new(:a))\n")).to be_empty
      expect(arg_mismatches("Class.new(Data.define(:a))\n")).to be_empty
      expect(arg_mismatches("Class.new(Class.new)\n")).to be_empty
    end

    it "still fires on invalid superclass arguments" do
      expect(arg_mismatches("Class.new(\"x\")\n"))
        .to include(a_string_matching(/expected Class, got "x"/))
      expect(arg_mismatches("Class.new(Struct.new(:a).new)\n"))
        .to include(a_string_matching(/expected Class/))
    end
  end
end
