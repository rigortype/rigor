# frozen_string_literal: true

# Integration spec for `plugins/rigor-minitest/`. Pillar 2 Slice 1 (sibling to rigor-rspec's matcher narrowing)
# — extends spec-derived flow facts to the Minitest / Test::Unit assertion API plus the Minitest/spec
# `_(x).must_*` / `.wont_*` matchers.

require "spec_helper"

MINITEST_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-minitest/lib", __dir__)
$LOAD_PATH.unshift(MINITEST_PLUGIN_LIB) unless $LOAD_PATH.include?(MINITEST_PLUGIN_LIB)
require "rigor-minitest"

RSpec.describe "plugins/rigor-minitest" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Minitest }
  let(:plugin) { plugin_class.allocate }

  def parse_call_node(source, locals: %i[x])
    Prism.parse(source, scopes: [locals]).value.statements.body.first
  end

  describe "assert_* / refute_* form (Minitest / Test::Unit)" do
    context "when assertion is assert_kind_of(T, x)" do
      it "emits a :local fact narrowing to Nominal[T]" do
        call_node = parse_call_node("assert_kind_of(String, x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_kind).to eq(:local)
        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
        expect(fact.negative).to be(false)
      end
    end

    context "when assertion is assert_instance_of(T, x)" do
      it "shares the assert_kind_of shape" do
        call_node = parse_call_node("assert_instance_of(Integer, x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end
    end

    context "when assertion is refute_kind_of(T, x)" do
      it "emits a negative :local fact" do
        call_node = parse_call_node("refute_kind_of(String, x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_not_kind_of(T, x) (Test::Unit alias)" do
      it "behaves like refute_kind_of" do
        call_node = parse_call_node("assert_not_kind_of(String, x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_nil(x)" do
      it "emits a :local fact narrowing to Constant<nil>" do
        call_node = parse_call_node("assert_nil(x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(false)
      end
    end

    context "when assertion is refute_nil(x)" do
      it "emits a negative :local fact (narrow AWAY from nil)" do
        call_node = parse_call_node("refute_nil(x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_not_nil(x) (Test::Unit alias)" do
      it "behaves like refute_nil" do
        call_node = parse_call_node("assert_not_nil(x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_equal(literal, x)" do
      it "narrows to Constant<integer> for an integer literal" do
        call_node = parse_call_node("assert_equal(42, x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(42))
      end

      it "narrows to Constant<string> for a string literal" do
        call_node = parse_call_node('assert_equal("hi", x)')
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of("hi"))
      end

      it "narrows to Constant<symbol> for a symbol literal" do
        call_node = parse_call_node("assert_equal(:foo, x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(:foo))
      end

      it "is silent for a non-literal expected" do
        call_node = parse_call_node("assert_equal(some_method, x)")
        expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
      end
    end

    context "when assertion is refute_equal(literal, x)" do
      it "emits a negative :local fact" do
        call_node = parse_call_node("refute_equal(42, x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(42))
        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_match(regex, x)" do
      it "narrows x to String" do
        call_node = parse_call_node("assert_match(/\\Afoo\\z/, x)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "is silent when the first arg is not a regex literal" do
        call_node = parse_call_node('assert_match("not_a_regex", x)')
        expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
      end
    end
  end

  describe "spec-style _(x).must_* / .wont_* form (Minitest/spec)" do
    context "when matcher is _(x).must_be_kind_of(T)" do
      it "emits a :local fact narrowing to Nominal[T]" do
        call_node = parse_call_node("_(x).must_be_kind_of(String)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end

    context "when matcher is value(x).must_be_a(T) (value wrapper alias)" do
      it "recognises the value() wrapper" do
        call_node = parse_call_node("value(x).must_be_a(Integer)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end
    end

    context "when matcher is expect(x).must_be_kind_of(T) (expect wrapper alias)" do
      it "recognises the expect() wrapper" do
        call_node = parse_call_node("expect(x).must_be_kind_of(String)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
      end
    end

    context "when matcher is _(x).must_be_nil" do
      it "emits a :local fact narrowing to Constant<nil>" do
        call_node = parse_call_node("_(x).must_be_nil")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(false)
      end
    end

    context "when matcher is _(x).wont_be_nil" do
      it "emits a negative :local fact" do
        call_node = parse_call_node("_(x).wont_be_nil")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(true)
      end
    end

    context "when matcher is _(x).must_equal(literal)" do
      it "narrows to Constant<literal>" do
        call_node = parse_call_node("_(x).must_equal(7)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(7))
      end
    end

    context "when matcher is _(x).must_match(/regex/)" do
      it "narrows to String" do
        call_node = parse_call_node("_(x).must_match(/\\d+/)")
        fact = plugin.type_specifier_facts(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end
  end

  describe "non-matching call shapes" do
    it "is silent for the legacy bare `x.must_be_kind_of(T)` (no wrapper)" do
      call_node = parse_call_node("x.must_be_kind_of(String)")
      expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
    end

    it "is silent for assert_predicate (not yet recognised)" do
      call_node = parse_call_node("assert_predicate(x, :foo?)")
      expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
    end

    it "is silent for assert_respond_to (not yet recognised)" do
      call_node = parse_call_node("assert_respond_to(x, :foo)")
      expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
    end

    it "is silent for assert_kind_of with non-local second arg" do
      call_node = parse_call_node("assert_kind_of(String, foo.bar)")
      expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
    end

    it "is silent for an unrelated method call" do
      call_node = parse_call_node("foo(x)")
      expect(plugin.type_specifier_facts(call_node: call_node, scope: nil)).to be_empty
    end
  end

  describe "when running end-to-end through the engine" do
    it "removes the possible-nil-receiver after refute_nil(x)" do
      result = run_plugin(
        source: <<~RUBY
          # @rbs (String | nil) -> void
          def test_refute_nil(x)
            refute_nil(x)
            x.upcase
          end
        RUBY
      )
      nil_recv = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
      expect(nil_recv).to be_empty
    end

    it "narrows x to Constant<42> after assert_equal(42, x) — downstream `x + 1` resolves" do
      result = run_plugin(
        source: <<~RUBY
          # @rbs (Integer | nil) -> void
          def test_assert_equal(x)
            assert_equal(42, x)
            x + 1
          end
        RUBY
      )
      nil_recv = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
      expect(nil_recv).to be_empty
    end

    it "narrows through _(x).must_be_kind_of(String) — downstream `.upcase` resolves" do
      result = run_plugin(
        source: <<~RUBY
          # @rbs (String | nil) -> void
          def test_spec(x)
            _(x).must_be_kind_of(String)
            x.upcase
          end
        RUBY
      )
      nil_recv = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
      expect(nil_recv).to be_empty
    end
  end
end
