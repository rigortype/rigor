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

  def scope_with_x(type)
    Rigor::Scope.empty.with_local(:x, type)
  end

  def nominal(name) = Rigor::Type::Combinator.nominal_of(name)
  def constant(value) = Rigor::Type::Combinator.constant_of(value)

  def equality_fact_type(source, x_type)
    facts = plugin.narrowing_facts_for(call_node: parse_call_node(source), scope: scope_with_x(x_type))
    facts.first&.type
  end

  describe "assert_* / refute_* form (Minitest / Test::Unit)" do
    context "when assertion is assert_kind_of(T, x)" do
      it "emits a :local fact narrowing to Nominal[T]" do
        call_node = parse_call_node("assert_kind_of(String, x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_kind).to eq(:local)
        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
        expect(fact.negative).to be(false)
      end
    end

    context "when assertion is assert_instance_of(T, x)" do
      it "shares the assert_kind_of shape" do
        call_node = parse_call_node("assert_instance_of(Integer, x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end
    end

    context "when assertion is refute_kind_of(T, x)" do
      it "emits a negative :local fact" do
        call_node = parse_call_node("refute_kind_of(String, x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_not_kind_of(T, x) (Test::Unit alias)" do
      it "behaves like refute_kind_of" do
        call_node = parse_call_node("assert_not_kind_of(String, x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_nil(x)" do
      it "emits a :local fact narrowing to Constant<nil>" do
        call_node = parse_call_node("assert_nil(x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(false)
      end
    end

    context "when assertion is refute_nil(x)" do
      it "emits a negative :local fact (narrow AWAY from nil)" do
        call_node = parse_call_node("refute_nil(x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_not_nil(x) (Test::Unit alias)" do
      it "behaves like refute_nil" do
        call_node = parse_call_node("assert_not_nil(x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_equal(literal, x)" do
      it "narrows to Constant<integer> for an integer literal" do
        call_node = parse_call_node("assert_equal(42, x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: scope_with_x(nominal("Integer"))).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(42))
      end

      it "narrows to Constant<string> for a string literal" do
        call_node = parse_call_node('assert_equal("hi", x)')
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: scope_with_x(nominal("String"))).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of("hi"))
      end

      it "narrows to Constant<symbol> for a symbol literal" do
        call_node = parse_call_node("assert_equal(:foo, x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(:foo))
      end

      it "is silent for a non-literal expected" do
        call_node = parse_call_node("assert_equal(some_method, x)")
        expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
      end

      # Issue #1678 — `assert_equal(exp, act)` passes on `exp == act`, which is not identity. The fact meets the
      # local's current type and never replaces it.
      it "narrows an identity literal (nil, true, false, Symbol) whatever the local's type" do
        dynamic = Rigor::Type::Combinator.untyped
        expect(equality_fact_type("assert_equal(:foo, x)", dynamic)).to eq(constant(:foo))
        expect(equality_fact_type("assert_equal(true, x)", nominal("Object"))).to eq(constant(true))
        expect(equality_fact_type("assert_equal(nil, x)", dynamic)).to eq(constant(nil))
      end

      it "is silent for a non-identity literal when the local is Dynamic or has no known type" do
        expect(equality_fact_type("assert_equal(9, x)", Rigor::Type::Combinator.untyped)).to be_nil
        expect(plugin.narrowing_facts_for(call_node: parse_call_node("assert_equal(9, x)"), scope: nil))
          .to be_empty
      end

      it "is silent when the local's class may define its own ==" do
        expect(equality_fact_type("assert_equal(9, x)", nominal("ModInt"))).to be_nil
        expect(equality_fact_type('assert_equal("a", x)', nominal("Object"))).to be_nil
      end

      it "is silent for a numeric literal of another class than the local's" do
        expect(equality_fact_type("assert_equal(9.0, x)", nominal("Integer"))).to be_nil
        expect(equality_fact_type("assert_equal(1, x)", constant(1.0))).to be_nil
        expect(equality_fact_type("assert_equal(9, x)", nominal("Numeric"))).to be_nil
      end

      it "is silent for a zero Float literal, which -0.0 also equals" do
        expect(equality_fact_type("assert_equal(0.0, x)", nominal("Float"))).to be_nil
      end

      it "meets an IntegerRange or a union of same-class constants" do
        range = Rigor::Type::Combinator.integer_range(0, 9)
        expect(equality_fact_type("assert_equal(9, x)", range)).to eq(constant(9))
        union = Rigor::Type::Combinator.union(constant(1), constant(2), constant(3))
        expect(equality_fact_type("assert_equal(2, x)", union)).to eq(constant(2))
      end

      it "drops nil, boolean and Symbol members, which an Integer literal cannot equal" do
        union = Rigor::Type::Combinator.union(nominal("Integer"), constant(nil))
        expect(equality_fact_type("assert_equal(42, x)", union)).to eq(constant(42))
      end

      it "is silent when no member of the local's type can equal the literal" do
        expect(equality_fact_type("assert_equal(10, x)", Rigor::Type::Combinator.integer_range(0, 9))).to be_nil
      end
    end

    context "when assertion is refute_equal(literal, x)" do
      it "emits a negative :local fact" do
        call_node = parse_call_node("refute_equal(42, x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(42))
        expect(fact.negative).to be(true)
      end
    end

    context "when assertion is assert_match(regex, x)" do
      it "narrows x to String" do
        call_node = parse_call_node("assert_match(/\\Afoo\\z/, x)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "is silent when the first arg is not a regex literal" do
        call_node = parse_call_node('assert_match("not_a_regex", x)')
        expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
      end
    end
  end

  describe "spec-style _(x).must_* / .wont_* form (Minitest/spec)" do
    context "when matcher is _(x).must_be_kind_of(T)" do
      it "emits a :local fact narrowing to Nominal[T]" do
        call_node = parse_call_node("_(x).must_be_kind_of(String)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end

    context "when matcher is value(x).must_be_a(T) (value wrapper alias)" do
      it "recognises the value() wrapper" do
        call_node = parse_call_node("value(x).must_be_a(Integer)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end
    end

    context "when matcher is expect(x).must_be_kind_of(T) (expect wrapper alias)" do
      it "recognises the expect() wrapper" do
        call_node = parse_call_node("expect(x).must_be_kind_of(String)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
      end
    end

    context "when matcher is _(x).must_be_nil" do
      it "emits a :local fact narrowing to Constant<nil>" do
        call_node = parse_call_node("_(x).must_be_nil")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(false)
      end
    end

    context "when matcher is _(x).wont_be_nil" do
      it "emits a negative :local fact" do
        call_node = parse_call_node("_(x).wont_be_nil")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(true)
      end
    end

    context "when matcher is _(x).must_equal(literal)" do
      it "narrows to Constant<literal>" do
        call_node = parse_call_node("_(x).must_equal(7)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: scope_with_x(nominal("Integer"))).first

        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(7))
      end

      it "is silent when the local's class may define its own == (issue #1678)" do
        expect(equality_fact_type("_(x).must_equal(9)", nominal("ModInt"))).to be_nil
        expect(equality_fact_type("_(x).must_equal(9)", Rigor::Type::Combinator.untyped)).to be_nil
      end

      it "narrows an identity literal whatever the local's type" do
        expect(equality_fact_type("_(x).must_equal(:ok)", Rigor::Type::Combinator.untyped)).to eq(constant(:ok))
      end
    end

    context "when matcher is _(x).wont_equal(literal)" do
      it "emits a negative fact, which leaves the local unchanged" do
        fact = plugin.narrowing_facts_for(call_node: parse_call_node("_(x).wont_equal(7)"), scope: nil).first

        expect(fact.type).to eq(constant(7))
        expect(fact.negative).to be(true)
      end
    end

    context "when matcher is _(x).must_match(/regex/)" do
      it "narrows to String" do
        call_node = parse_call_node("_(x).must_match(/\\d+/)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end
  end

  describe "non-matching call shapes" do
    it "is silent for the legacy bare `x.must_be_kind_of(T)` (no wrapper)" do
      call_node = parse_call_node("x.must_be_kind_of(String)")
      expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
    end

    it "is silent for assert_predicate (not yet recognised)" do
      call_node = parse_call_node("assert_predicate(x, :foo?)")
      expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
    end

    it "is silent for assert_respond_to (not yet recognised)" do
      call_node = parse_call_node("assert_respond_to(x, :foo)")
      expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
    end

    it "is silent for assert_kind_of with non-local second arg" do
      call_node = parse_call_node("assert_kind_of(String, foo.bar)")
      expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
    end

    it "is silent for an unrelated method call" do
      call_node = parse_call_node("foo(x)")
      expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
    end
  end

  describe "when running end-to-end through the engine" do
    let(:typed_mod_int_sig) do
      <<~RBS
        class TypedModInt
          def initialize: (Integer) -> void
          def inc!: () -> TypedModInt
          def ==: (untyped) -> bool
        end
      RBS
    end

    let(:modint_test) do
      <<~RUBY
        class ModIntTest < Minitest::Test
          def test_inc!
            m = ModInt(20)
            assert_equal 9, m
            assert_equal 10, m.inc!
            _(m).must_equal 10
            m.inc!
          end

          def test_typed_inc!
            m = TypedModInt.new(20)
            assert_equal 9, m
            assert_type("TypedModInt", m)
            assert_equal 10, m.inc!
            _(m).must_equal 10
            m.inc!
          end
        end
      RUBY
    end

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

    # Issue #1678 — from ac-library-rb's `test/modint_test.rb`: `ModInt#==` compares `to_i`, so
    # `assert_equal 9, m` passes for a ModInt and `m` must keep its type.
    it "keeps a Dynamic or RBS-typed local whose class defines its own == after assert_equal / must_equal" do
      result = run_plugin(source: modint_test, files: { "sig/typed_mod_int.rbs" => typed_mod_int_sig },
                          signature_paths: ["sig"])
      expect(result.diagnostics.map { |d| "#{d.line}: #{d.rule} #{d.message}" }).to be_empty
    end

    it "still narrows an Integer local to the literal it is asserted equal to" do
      result = run_plugin(
        source: <<~RUBY
          class RandTest < Minitest::Test
            def test_rand
              x = rand(10)
              assert_equal 9, x
              assert_type("9", x)
              y = rand(10)
              _(y).must_equal 3
              assert_type("3", y)
              z = rand(10)
              assert_equal 9.0, z
              assert_type("Integer", z)
            end
          end
        RUBY
      )
      expect(result.diagnostics.map { |d| "#{d.line}: #{d.rule} #{d.message}" }).to be_empty
    end

    it "leaves the local unchanged after refute_equal / wont_equal" do
      result = run_plugin(
        source: <<~RUBY
          class RefuteTest < Minitest::Test
            def test_refute
              x = [1, 2].sample
              refute_equal 1, x
              assert_type("1 | 2", x)
              _(x).wont_equal 2
              assert_type("1 | 2", x)
            end
          end
        RUBY
      )
      expect(result.diagnostics.map { |d| "#{d.line}: #{d.rule} #{d.message}" }).to be_empty
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
