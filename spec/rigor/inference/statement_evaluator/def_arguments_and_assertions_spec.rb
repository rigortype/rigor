# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `StatementEvaluator::DefArgumentsAndAssertions` evaluates a `def` passed as a call argument and applies
# the post-return facts a statement call contributes: the RSpec matcher shapes, the plugins' `narrowing_facts` and
# an `RBS::Extended` `assert` annotation. The examples call its entries directly, over a scope from `Scope.empty`, with
# a stub evaluator where the module calls back (`eval_def`, its only callback) and a stub plugin registry for the
# plugin path; the `RBS::Extended` example goes through the runner because it needs a loaded signature.
RSpec.describe Rigor::Inference::StatementEvaluator::DefArgumentsAndAssertions do
  let(:combinator) { Rigor::Type::Combinator }
  let(:integer) { combinator.nominal_of("Integer") }
  let(:string) { combinator.nominal_of("String") }
  let(:nil_type) { combinator.constant_of(nil) }
  let(:optional_integer) { combinator.union(integer, nil_type) }
  let(:scope) { Rigor::Scope.empty.with_local(:x, optional_integer) }

  # `x` is a local of the snippet, so `expect(x)` reads a `LocalVariableReadNode` as it does in a real body.
  def call_node(source) = Prism.parse(source, scopes: [[:x]]).value.statements.body.first

  describe ".evaluate_def_arguments" do
    let(:host_class) do
      Struct.new(:evaluated) do
        def eval_def(node)
          evaluated << node
        end
      end
    end

    it "hands every `def` argument to the evaluator, in order, and nothing else" do
      host = host_class.new([])
      call = call_node("wrap(1, def a; end, :sym, def b; end)")

      described_class.evaluate_def_arguments(call, host)

      expect(host.evaluated.map(&:name)).to eq(%i[a b])
    end

    it "does nothing for a call without arguments" do
      host = host_class.new([])

      described_class.evaluate_def_arguments(call_node("wrap"), host)

      expect(host.evaluated).to be_empty
    end

    it "does not evaluate a `def` that is the call's receiver or block" do
      host = host_class.new([])

      described_class.evaluate_def_arguments(call_node("(def a; end).wrap { def b; end }"), host)

      expect(host.evaluated).to be_empty
    end
  end

  describe ".apply_rspec_matcher_narrowing" do
    def narrowed(source, start = scope)
      described_class.apply_rspec_matcher_narrowing(call_node(source), start).local(:x)
    end

    it "narrows the local away from nil for `not_to be_nil` and `to_not be_nil`" do
      expect(narrowed("expect(x).not_to be_nil")).to eq(integer)
      expect(narrowed("expect(x).to_not be_nil")).to eq(integer)
    end

    it "narrows the local to the class for `to be_a(C)` and `to be_kind_of(C)`" do
      start = scope.with_local(:x, combinator.untyped)

      expect(narrowed("expect(x).to be_a(Integer)", start)).to eq(integer)
      expect(narrowed("expect(x).to be_kind_of(String)", start)).to eq(string)
    end

    it "takes a qualified class name for the argument" do
      start = scope.with_local(:x, combinator.untyped)

      expect(narrowed("expect(x).to be_a(Rigor::Scope)", start)).to eq(combinator.nominal_of("Rigor::Scope"))
    end

    it "narrows exactly for the `instance_of` matchers and by subtype for the others" do
      start = scope.with_local(:x, combinator.nominal_of("Numeric"))

      expect(narrowed("expect(x).to be_an_instance_of(Integer)", start)).to eq(integer)
      expect(narrowed("expect(x).to be_instance_of(Integer)", start)).to eq(integer)
      expect(narrowed("expect(x).to be_a(Numeric)", start)).to eq(combinator.nominal_of("Numeric"))
      # An Integer is a Numeric but not exactly one: only the subtype-permitting matcher keeps it.
      expect(narrowed("expect(x).to be_a(Numeric)", scope.with_local(:x, integer))).to eq(integer)
      expect(narrowed("expect(x).to be_an_instance_of(Numeric)", scope.with_local(:x, integer)))
        .to eq(combinator.bot)
    end

    it "leaves the scope alone for a shape it does not recognise" do
      [
        "expect(x).to eq(1)",
        "expect(x).to be_a(1)",
        "expect(x).to be_a(Integer, String)",
        "expect(x).to be_a(Integer) { }",
        "expect(x).not_to be_a(Integer)",
        "expect(x, 1).not_to be_nil",
        "expect(x.y).not_to be_nil",
        "other(x).not_to be_nil",
        "self.expect(x).not_to be_nil",
        "expect(x).not_to be_nil(1)",
        "expect(unbound).not_to be_nil",
        "expect(x).to eq(x)",
        "expect(x).not_to be_empty",
        "expect(x).to RSpec::Matchers.be_a(Integer)",
        "expect(x).to self.be_a(Integer)",
        "expect(x).to"
      ].each do |source|
        expect(narrowed(source)).to eq(optional_integer), source
      end
    end

    it "narrows only a local the `expect` argument reads, not one a call on it names" do
      start = scope.with_local(:y, optional_integer)
      narrowed_scope = described_class.apply_rspec_matcher_narrowing(call_node("expect(x.y).not_to be_nil"), start)

      expect([narrowed_scope.local(:x), narrowed_scope.local(:y)]).to eq([optional_integer, optional_integer])
    end
  end

  describe ".apply_plugin_assertions" do
    def fact_class = Rigor::FlowContribution::Fact

    def plugin_class
      Struct.new(:facts, :seen) do
        def narrowing_facts_for(call_node:, scope:)
          seen << [call_node, scope]
          facts
        end
      end
    end

    def registry_class
      Struct.new(:contribution_index) do
        def empty? = false
      end
    end

    # The registry's two gates, each a method name predicate: the global one (`statement_candidate?`) and the
    # per-plugin one (`narrowing_facts_candidate_for?`). Each defaults to naming only `narrow_x`.
    def index_class
      Struct.new(:plugins, :statement_gate, :plugin_gate) do
        def for_statement = plugins

        def statement_candidate?(name) = statement_gate.call(name)

        def narrowing_facts_candidate_for?(_plugin, name) = plugin_gate.call(name)
      end
    end

    def environment_class = Struct.new(:plugin_registry)

    def only_narrow_x = ->(name) { name == :narrow_x }

    def scope_with(plugins, statement_gate: only_narrow_x, plugin_gate: only_narrow_x)
      registry = registry_class.new(index_class.new(plugins, statement_gate, plugin_gate))
      Rigor::Scope.empty(environment: environment_class.new(registry))
                  .with_local(:x, Rigor::Type::Combinator.untyped)
    end

    def apply(source, plugins, tracer = nil, **gates)
      described_class.apply_plugin_assertions(call_node(source), scope_with(plugins, **gates), tracer)
    end

    it "applies a :local fact a plugin contributes for a call its gate names" do
      plugin = plugin_class.new([fact_class.new(target_kind: :local, target_name: :x, type: string)], [])

      expect(apply("narrow_x(1)", [plugin]).local(:x)).to eq(string)
      expect(plugin.seen.size).to eq(1)
    end

    it "never asks a plugin about a call the registry-wide gate does not name" do
      plugin = plugin_class.new([fact_class.new(target_kind: :local, target_name: :x, type: string)], [])

      result = apply("other_call(1)", [plugin], plugin_gate: ->(_name) { true })

      expect(plugin.seen).to be_empty
      expect(result.local(:x)).to eq(combinator.untyped)
    end

    it "never asks a plugin about a call its own gate does not name" do
      plugin = plugin_class.new([fact_class.new(target_kind: :local, target_name: :x, type: string)], [])

      result = apply("other_call(1)", [plugin], statement_gate: ->(_name) { true })

      expect(plugin.seen).to be_empty
      expect(result.local(:x)).to eq(combinator.untyped)
    end

    it "keeps going past a plugin that raises" do
      raising = Object.new
      def raising.narrowing_facts_for(call_node:, scope:) = raise("boom #{call_node} #{scope}")
      plugin = plugin_class.new([fact_class.new(target_kind: :local, target_name: :x, type: string)], [])

      expect(apply("narrow_x(1)", [raising, plugin]).local(:x)).to eq(string)
    end

    it "leaves the scope as it was for a :local fact that names a local the scope does not bind" do
      plugin = plugin_class.new([fact_class.new(target_kind: :local, target_name: :missing, type: string)], [])
      start = scope_with([plugin])

      result = described_class.apply_plugin_assertions(call_node("narrow_x(1)"), start, nil)

      expect(result).to equal(start)
    end

    it "narrows `self` for a :self fact on a receiver-less call" do
      plugin = plugin_class.new([fact_class.new(target_kind: :self, target_name: :self, type: string)], [])
      start = scope_with([plugin]).with_self_type(combinator.untyped)

      result = described_class.apply_plugin_assertions(call_node("narrow_x"), start, nil)

      expect(result.self_type).to eq(string)
    end

    it "narrows the receiver local for a :self fact on a call with a local receiver" do
      plugin = plugin_class.new([fact_class.new(target_kind: :self, target_name: :self, type: string)], [])

      expect(apply("x.narrow_x", [plugin]).local(:x)).to eq(string)
    end

    it "does nothing when the registry is empty or absent" do
      empty = Struct.new(:contribution_index) { def empty? = true }.new(nil)
      with_empty = Rigor::Scope.empty(environment: environment_class.new(empty))

      expect(described_class.apply_plugin_assertions(call_node("narrow_x"), with_empty, nil)).to equal(with_empty)
      expect(described_class.apply_plugin_assertions(call_node("narrow_x"), Rigor::Scope.empty, nil))
        .to be_a(Rigor::Scope)
    end
  end

  describe ".apply_rbs_extended_assertions", type: :runner do
    it "narrows the argument an `assert` annotation names once the call returns" do
      result = analyze(<<~RUBY, sig: { "asserts.rbs" => <<~RBS })
        def run(x)
          Asserts.assert_string!(x)
          Rigor.dump_type(x)
        end
      RUBY
        class Asserts
          %a{rigor:v1:assert value is String}
          def self.assert_string!: (untyped value) -> void
        end
      RBS

      expect(result.diagnostics.map(&:message)).to include("dump_type: String")
    end

    it "leaves a call whose receiver has no known class alone" do
      scope_with_x = Rigor::Scope.empty.with_local(:x, combinator.untyped)

      result = described_class.apply_rbs_extended_assertions(call_node("unknown_thing.check!(x)"), scope_with_x, nil)

      expect(result).to equal(scope_with_x)
    end
  end
end
