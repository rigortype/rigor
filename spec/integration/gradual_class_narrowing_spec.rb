# frozen_string_literal: true

# Issue #2656 — a class guard on a gradual value narrows it to the nominal class, so the narrowed value failed a
# literal-typed parameter on correct code (`def f(x) = (Sink.new.mode(x) if x.is_a?(String))` reported `got String`).
# The binding keeps the `Nominal` (dispatch, `call.undefined-method` and `call.wrong-arity` still read it) and carries a
# gradual-narrowing mark, under which `call.argument-type-mismatch` judges it by its class rather than against the
# parameter's literals.
require "spec_helper"

RSpec.describe "a class guard keeps a gradual value gradual (#2656)", type: :runner do
  let(:signature) do
    { "sink.rbs" => "class Sink\n  def mode: (\"r\" | \"w\") -> void\n  def num: (1 | 2) -> void\n  " \
                    "def pick: (Integer) -> void | (Symbol) -> void\nend\n" }
  end

  def mismatches(source)
    analyze(source, sig: signature).diagnostics.map(&:qualified_rule).grep(/argument-type-mismatch/)
  end

  it "fires for a bad literal (the control that the rule is live)" do
    expect(mismatches("Sink.new.mode(\"x\")\n")).to eq(["call.argument-type-mismatch"])
  end

  it "fires for a String the narrowed value computes (the control that dispatch reads the narrowed class)" do
    source = "def f(x) = (Sink.new.mode(x.to_s) if x.is_a?(Integer))\n"
    expect(mismatches(source)).to eq(["call.argument-type-mismatch"])
  end

  {
    "is_a?" => "def f(x) = (Sink.new.mode(x) if x.is_a?(String))",
    "kind_of?" => "def f(x) = (Sink.new.mode(x) if x.kind_of?(String))",
    "instance_of?" => "def f(x) = (Sink.new.mode(x) if x.instance_of?(String))",
    "===" => "def f(x) = (Sink.new.mode(x) if String === x)",
    "case/when" => "def f(x)\n  case x\n  when String then Sink.new.mode(x)\n  end\nend",
    "case/in" => "def f(x)\n  case x\n  in String then Sink.new.mode(x)\n  end\nend",
    "an `in String => s` capture" => "def f(x)\n  case x\n  in String => s then Sink.new.mode(s)\n  end\nend"
  }.each do |guard, source|
    it "stays silent for an untyped parameter narrowed by #{guard}" do
      expect(mismatches("#{source}\n")).to eq([])
    end
  end

  it "fires for a narrowed value copied to another local (the mark is not transitive)" do
    expect(mismatches("def f(x)\n  return unless x.is_a?(String)\n  y = x\n  Sink.new.mode(y)\nend\n"))
      .to eq(["call.argument-type-mismatch"])
  end

  it "fires for a class no overload accepts (guard: the overload path judges by class already)" do
    expect(mismatches("def f(x) = (Sink.new.pick(x) if x.is_a?(String))\n")).to eq(["call.argument-type-mismatch"])
  end

  it "fires for a class the literal-typed parameter can never hold" do
    expect(mismatches("def f(x) = (Sink.new.num(x) if x.is_a?(String))\n")).to eq(["call.argument-type-mismatch"])
  end

  it "fires for a String-typed local narrowed by is_a? (only a gradual value is marked)" do
    source = "def f(s)\n  x = [s].join\n  Sink.new.mode(x) if x.is_a?(String)\nend\n"
    expect(mismatches(source)).to eq(["call.argument-type-mismatch"])
  end

  it "fires once the narrowed local is rebound (a write drops the mark)" do
    source = "def f(x)\n  return unless x.is_a?(String)\n  x = x.upcase\n  Sink.new.mode(x)\nend\n"
    expect(mismatches(source)).to eq(["call.argument-type-mismatch"])
  end

  it "keeps call.undefined-method on the narrowed value (the true-positive control)" do
    rules = analyze("def f(x) = (x.upcase if x.is_a?(Integer))\n", sig: signature).diagnostics.map(&:qualified_rule)
    expect(rules).to include("call.undefined-method")
  end

  it "keeps call.wrong-arity on the narrowed value (the true-positive control)" do
    source = "def f(x) = (x.upcase(1, 2, 3) if x.is_a?(String))\n"
    rules = analyze(source, sig: signature).diagnostics.map(&:qualified_rule)
    expect(rules).to include("call.wrong-arity")
  end

  it "stays silent for a `case v when String / when Integer` over a gradual element" do
    source = <<~RUBY
      def f(list)
        list.each do |v|
          case v
          when String then Sink.new.mode(v)
          when Integer then Sink.new.num(v)
          end
        end
      end
    RUBY
    expect(mismatches(source)).to eq([])
  end
end
