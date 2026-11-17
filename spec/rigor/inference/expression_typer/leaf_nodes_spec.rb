# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `ExpressionTyper::LeafNodes` types the nodes whose answer is a literal carrier or one binding read from
# the scope. The examples parse a snippet and call the entry with the scope and a real typer over it, the way
# `ExpressionTyper`'s delegators do, so each is checked against the module and not through `PRISM_DISPATCH`.
#
# Two guards no example distinguishes, after trying the inputs named:
#
# - `symbol_type_for`'s `return nominal_of(Symbol) if raw.nil?` and `string_type_for`'s `return nominal_of(String) if
#   unescaped.nil?`. A `SymbolNode#value` / `StringNode#unescaped` is nil only for a node Prism builds under an
#   interpolation (`:"a#{b}"` is an `InterpolatedSymbolNode`, `"a#{b}"` an `InterpolatedStringNode`), which never
#   reaches these two entries; tried a plain, an empty, a `%s()`, a `?a` character, a heredoc and a `%w` element, and
#   each reads a String value.
RSpec.describe Rigor::Inference::ExpressionTyper::LeafNodes do
  let(:combinator) { Rigor::Type::Combinator }
  let(:scope) { Rigor::Scope.empty }
  let(:typer) { Rigor::Inference::ExpressionTyper.new(scope: scope) }
  let(:integer) { combinator.nominal_of("Integer") }
  let(:string) { combinator.nominal_of("String") }

  def node_of(source, scopes: []) = Prism.parse(source, scopes: scopes).value.statements.body.first

  def typer_over(scope) = Rigor::Inference::ExpressionTyper.new(scope: scope)

  describe "literals" do
    it "types an integer, float, rational and imaginary literal as the Constant of its value" do
      expect(described_class.type_of_literal_value(node_of("42")).describe).to eq("42")
      expect(described_class.type_of_literal_value(node_of("2.5")).describe).to eq("2.5")
      expect(described_class.type_of_literal_value(node_of("3r")).value).to eq(3r)
      expect(described_class.type_of_literal_value(node_of("2i")).value).to eq(2i)
    end

    it "types true, false and nil as their Constants" do
      expect(described_class.type_of_true(node_of("true")).describe).to eq("true")
      expect(described_class.type_of_false(node_of("false")).describe).to eq("false")
      expect(described_class.type_of_nil(node_of("nil")).describe).to eq("nil")
    end

    it "types a symbol and a string literal as the Constant of their value" do
      expect(described_class.symbol_type_for(node_of(":sym")).describe).to eq(":sym")
      expect(described_class.string_type_for(node_of('"hi"')).describe).to eq('"hi"')
      expect(described_class.string_type_for(node_of('"a\nb"')).value).to eq("a\nb")
    end

    it "types an interpolated symbol as Nominal[Symbol] and a backtick command as Nominal[String]" do
      expect(described_class.type_of_interpolated_symbol(node_of(":\"a\#{b}\"")).describe).to eq("Symbol")
      expect(described_class.type_of_xstring(node_of("`echo hi`")).describe).to eq("String")
    end

    it "types __FILE__ as non-empty-string and __LINE__ as positive-int" do
      expect(described_class.type_of_source_file(node_of("__FILE__")).describe).to eq("non-empty-string")
      expect(described_class.type_of_source_line(node_of("__LINE__")).describe).to eq("positive-int")
    end

    it "types a regexp literal as the Constant of the Regexp" do
      type = described_class.type_of_regexp(node_of("/a+/i"))

      expect(type.value).to eq(/a+/i)
    end

    it "types an interpolated regexp as Nominal[Regexp]" do
      expect(described_class.type_of_regexp(node_of("/a\#{x}/"))).to eq(combinator.nominal_of(Regexp))
    end

    it "types a regexp Ruby refuses to build as Nominal[Regexp] instead of raising" do
      # Prism accepts the literal; `Regexp.new` refuses the lookbehind below.
      node = node_of("/(?<=a*)b/")

      expect(described_class.type_of_regexp(node)).to eq(combinator.nominal_of(Regexp))
    end

    it "types a lambda literal as Nominal[Proc]" do
      expect(described_class.type_of_lambda(node_of("-> { 1 }")).describe).to eq("Proc")
    end

    it "types `defined?` and a pattern-match predicate as the union their results span" do
      expect(described_class.type_of_defined(node_of("defined?(x)")).describe).to eq("String?")
      expect(described_class.type_of_match_predicate(node_of("1 in Integer")).describe).to eq("bool")
    end

    it "types a one-line pattern assertion as nil and a definition expression as its name or nil" do
      expect(described_class.type_of_match_required(node_of("1 => Integer")).describe).to eq("nil")
      expect(described_class.type_of_def(node_of("def foo; end")).describe).to eq(":foo")
      expect(described_class.type_of_nil_value(node_of("alias a b")).describe).to eq("nil")
    end

    it "types a jump as bot, which absorbs under union" do
      expect(described_class.type_of_jump(node_of("return 1")).describe).to eq("bot")
    end
  end

  describe "match globals" do
    it "types a numbered or back reference as String | nil when the scope binds nothing" do
      expect(described_class.type_of_numbered_reference(node_of("$1"), scope).describe).to eq("String?")
      expect(described_class.type_of_back_reference(node_of("$&"), scope).describe).to eq("String?")
    end

    it "prefers the type the scope bound for the reference" do
      bound = scope.with_global(:$1, string).with_global(:$&, string)

      expect(described_class.type_of_numbered_reference(node_of("$1"), bound)).to equal(string)
      expect(described_class.type_of_back_reference(node_of("$&"), bound)).to equal(string)
    end
  end

  describe "variable reads" do
    it "reads a local from the scope, and `Dynamic[top]` when it is unbound" do
      bound = scope.with_local(:x, integer)
      node = node_of("x", scopes: [[:x]])

      expect(described_class.local_read(node, bound, typer_over(bound))).to equal(integer)
      expect(described_class.local_read(node, scope, typer)).to equal(combinator.untyped)
    end

    it "reads the implicit `it` local from the scope" do
      bound = scope.with_local(:it, integer)
      node = node_of("[1].each { it }").block.body.body.first

      expect(described_class.it_read(node, bound, typer_over(bound))).to equal(integer)
      expect(described_class.it_read(node, scope, typer)).to equal(combinator.untyped)
    end

    it "reads an instance, class and global variable from the scope, and `Dynamic[top]` when unbound" do
      bound = scope.with_ivar(:@a, integer).with_cvar(:@@b, integer).with_global(:$c, integer)

      expect(described_class.type_of_instance_variable_read(node_of("@a"), bound, typer_over(bound))).to equal(integer)
      expect(described_class.type_of_class_variable_read(node_of("@@b"), bound, typer_over(bound))).to equal(integer)
      expect(described_class.type_of_global_variable_read(node_of("$c"), bound, typer_over(bound))).to equal(integer)
      expect(described_class.type_of_instance_variable_read(node_of("@a"), scope, typer)).to equal(combinator.untyped)
      expect(described_class.type_of_class_variable_read(node_of("@@b"), scope, typer)).to equal(combinator.untyped)
      expect(described_class.type_of_global_variable_read(node_of("$c"), scope, typer)).to equal(combinator.untyped)
    end

    it "types `self` as the scope's self type, and `Dynamic[top]` at the top level" do
      inside = scope.with_self_type(string)

      expect(described_class.type_of_self_node(node_of("self"), inside, typer_over(inside))).to equal(string)
      expect(described_class.type_of_self_node(node_of("self"), scope, typer)).to equal(combinator.untyped)
    end
  end

  describe "non-value positions" do
    it "answers `Dynamic[top]` for a parameter list, an embedded variable and a `Dynamic` stand-in" do
      expect(described_class.type_of_non_value(node_of("def f(a); end").parameters, typer)).to equal(combinator.untyped)
      expect(described_class.type_of_dynamic_top(node_of("super"), typer)).to equal(combinator.untyped)
    end

    it "types `yield` as the block value the call-site frame carries, and `Dynamic[top]` outside one" do
      node = node_of("yield")

      expect(described_class.type_of_yield(node, typer)).to equal(combinator.untyped)
      Rigor::Inference::ExpressionTyper.with_yield_value_type(integer) do
        expect(described_class.type_of_yield(node, typer)).to equal(integer)
      end
    end
  end
end
