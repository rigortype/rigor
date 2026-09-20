# frozen_string_literal: true

require "spec_helper"

# Issue #1101 — `Scope#plugin_typed_calls` is the one recording in `MethodDispatcher#resolve` that is
# SET-ONLY: the table has no removal, and `CheckRules#call_site_exempt?` / `#source_arity_envelope` read
# it as an exemption from `call.undefined-method` and `call.wrong-arity`. The composite-receiver tier
# re-enters `resolve` once per projected member, so a member a plugin answers beside a member that
# declines would leave the node marked plugin-typed for a call this dispatcher never typed.
#
# The tier therefore BUFFERS the record and commits it only when it answers. Everything else `resolve`
# records is `record_dynamic_origin`, which is last-wins and overwritten by the caller's fail-soft
# widening, so it needs no such care.
#
# This file pins the dispatcher-level contract. The SUPPRESSION it prevents is real and reachable, and
# `spec/integration/composite_receiver_plugin_typed_suppression_spec.rb` is the end-to-end proof:
# `call_site_exempt?` runs ahead of the receiver-shape branch, so it covers
# `union_undefined_method_diagnostic` too, and a stuck record silences a genuine union miss. An earlier
# draft of this header claimed no `rigor check` fixture could reach it, on the strength of a probe whose
# project classes had no `sig/` — which made every arm an ADR-26 open receiver and the union rule
# silent for a reason that had nothing to do with the record. Closing the receivers is the ingredient
# that probe lacked.
RSpec.describe "MethodDispatcher composite-receiver plugin-typed recording" do
  def comb = Rigor::Type::Combinator

  # Gated on `receivers: ["Integer"]` so the rule answers for ONE member of the unions below and not the
  # other. Core classes keep the receiver-ancestry gate out of the question.
  let(:plugin_class) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "compositetest", version: "0.1.0")

      dynamic_return receivers: ["Integer"], methods: [:vanish] do |_call_node, _scope|
        Rigor::Type::Combinator.nominal_of("Widgetish")
      end

      dynamic_return receivers: ["String"], methods: [:vanish] do |_call_node, _scope|
        Rigor::Type::Combinator.nominal_of("Gadgetish")
      end
    end
    stub_const("FakeCompositePlugin", klass)
    klass
  end

  # The registry holds plugin INSTANCES, and `dynamic_return_type` is an instance method.
  let(:plugin) do
    plugin_class.new(
      services: Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection,
        type: Rigor::Type::Combinator,
        configuration: Rigor::Configuration.new
      )
    )
  end

  let(:environment) do
    Rigor::Environment.new(
      rbs_loader: Rigor::Environment::RbsLoader.default,
      plugin_registry: Rigor::Plugin::Registry.new(plugins: [plugin])
    )
  end

  let(:scope) { Rigor::Scope.new(environment: environment, locals: {}) }

  def call_node(selector)
    Prism.parse("x.#{selector}").value.statements.body.first
  end

  def dispatch(receiver, selector)
    node = call_node(selector)
    result = Rigor::Inference::MethodDispatcher.dispatch(
      receiver_type: receiver, method_name: node.name, arg_types: [],
      environment: environment, call_node: node, scope: scope
    )
    [result, scope.plugin_typed_call?(node)]
  end

  it "CONTROL: a plugin answering a scalar receiver still marks the call plugin-typed (#653)" do
    # Discriminates every example below: without this, a fixture where the plugin never fires at all
    # would produce the same "not marked" reading as the deferral working.
    result, marked = dispatch(comb.nominal_of("Integer"), :vanish)

    expect(result).to eq(comb.nominal_of("Widgetish"))
    expect(marked).to be(true)
  end

  it "does NOT mark the call when a plugin answers one member and another member declines" do
    # No rule is gated on `ProjectOnlyWidget`, it has no RBS, and `Object` carries no `#vanish`, so that
    # member declines and the tier declines with it — the site's type is not the plugin's. Marking it
    # would exempt a call nothing answered from `call.undefined-method` / `call.wrong-arity`.
    receiver = comb.union(comb.nominal_of("Integer"), comb.nominal_of("ProjectOnlyWidget"))
    result, marked = dispatch(receiver, :vanish)

    expect(result).to be_nil
    expect(marked).to be(false)
  end

  it "marks the call when the tier DOES answer with a plugin-answered member in the union" do
    # The other half of the contract: a plugin supplied the answer, so #653's exemption applies exactly
    # as it does on the scalar path. The asserted type is the per-member union, which ONLY this tier
    # can produce: the plugin tier above it sees the whole `Integer | String` carrier, which neither
    # `receivers:` gate matches, and no RBS declares `#vanish`.
    receiver = comb.union(comb.nominal_of("Integer"), comb.nominal_of("String"))
    result, marked = dispatch(receiver, :vanish)

    expect(result).to eq(comb.union(comb.nominal_of("Gadgetish"), comb.nominal_of("Widgetish")))
    expect(marked).to be(true)
  end
end
