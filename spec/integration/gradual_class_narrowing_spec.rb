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
                    "def pick: (Integer) -> void | (Symbol) -> void\n  def sym: (\"r\" | :w) -> void\nend\n" }
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

  # A later guard narrows the marked local; it does not write it, so the mark stays.
  {
    "a nil guard" => "return unless x.is_a?(String)\n  return if x.nil?\n  Sink.new.mode(x)",
    "an equality guard" => "return unless x.is_a?(String)\n  return if x == \"\"\n  Sink.new.mode(x)",
    "an `&&` operand" => "Sink.new.mode(x) if x.is_a?(String) && x != \"\"",
    "a second class guard" => "return unless x.is_a?(String)\n  return unless x.is_a?(Comparable)\n  Sink.new.mode(x)",
    "a nested class guard" => "if x.is_a?(Object)\n    Sink.new.mode(x) if x.is_a?(String)\n  end"
  }.each do |guard, body|
    it "stays silent after #{guard} on the marked local" do
      expect(mismatches("def f(x)\n  #{body}\nend\n")).to eq([])
    end
  end

  {
    "a literal joined with a gradual value" => "x = h[:m] || \"r\"",
    "a nil-able gradual value" => "x = c ? h[:m] : nil"
  }.each do |shape, write|
    it "stays silent for #{shape} narrowed by is_a?" do
      expect(mismatches("def f(h, c)\n  #{write}\n  Sink.new.mode(x) if x.is_a?(String)\nend\n")).to eq([])
    end
  end

  it "judges a literal member as itself (the static part is not read past)" do
    source = "def f(h)\n  x = h[:m] || \"q\"\n  Sink.new.mode(x) if x.is_a?(String)\nend\n"
    expect(mismatches(source)).to eq(["call.argument-type-mismatch"])
  end

  it "stays silent for a second case over an element a first case narrowed and rejoined" do
    source = <<~RUBY
      def f(list)
        list.each do |v|
          case v
          when String then Sink.new.mode(v)
          end
          case v
          when Integer then Sink.new.num(v)
          end
        end
      end
    RUBY
    expect(mismatches(source)).to eq([])
  end

  it "fires when the predicate itself writes the marked local (guard: the write rebinds it before the edges)" do
    source = "def f(x)\n  return unless x.is_a?(String)\n  Sink.new.mode(x) if (x = [x].join)\nend\n"
    expect(mismatches(source)).to eq(["call.argument-type-mismatch"])
  end

  it "fires after a join with an arm that wrote the local (the mark intersects at a join)" do
    source = "def f(x, c)\n  return unless x.is_a?(String)\n  x = x.upcase if c\n  Sink.new.mode(x)\nend\n"
    expect(mismatches(source)).to eq(["call.argument-type-mismatch"])
  end

  it "stays silent for an alternation capture" do
    expect(mismatches("def f(x)\n  case x\n  in String | Symbol => s then Sink.new.sym(s)\n  end\nend\n")).to eq([])
  end

  {
    "a `when` clause" => "case x\n  when String then Sink.new.mode(x)\n  end",
    "a `case` else arm" => "case x\n  when Integer then 1\n  else Sink.new.mode(x)\n  end",
    "a class capture" => "case x\n  in String => s then Sink.new.mode(s)\n  end"
  }.each do |shape, body|
    it "stays silent for #{shape} over a local an earlier guard marked" do
      source = "def f(x)\n  return unless x.is_a?(String)\n  #{body}\nend\n"
      expect(mismatches(source)).to eq([])
    end
  end

  {
    "a literal `when`" => "case x\n  when \"r\" then Sink.new.mode(x)\n  end",
    "a `when` with several literals" => "case x\n  when \"r\", \"w\" then Sink.new.mode(x)\n  end"
  }.each do |shape, body|
    it "keeps the mark of a marked subject under #{shape}" do
      expect(mismatches("def f(x)\n  return unless x.is_a?(String)\n  #{body}\nend\n")).to eq([])
    end
  end

  it "fires for a union whose static member narrows to a class (only the gradual part is read past)" do
    source = "def f(h, s)\n  d = \"a\" + s.to_s\n  x = h[:m] || d\n  Sink.new.mode(x) if x.is_a?(String)\nend\n"
    expect(mismatches(source)).to eq(["call.argument-type-mismatch"])
  end

  it "stays silent for a union whose static member the guard rules out" do
    source = "def f(h, s)\n  x = h[:m] || s.to_s.size\n  Sink.new.mode(x) if x.is_a?(String)\nend\n"
    expect(mismatches(source)).to eq([])
  end

  it "fires inside a block that writes the marked local (a later run reads the write)" do
    source = "def f(x)\n  return unless x.is_a?(String)\n  loop do\n    Sink.new.mode(x)\n    " \
             "x = \"zz\".dup\n  end\nend\n"
    expect(mismatches(source)).to eq(["call.argument-type-mismatch"])
  end
end
