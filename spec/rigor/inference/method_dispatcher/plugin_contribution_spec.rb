# frozen_string_literal: true

require "spec_helper"

# The plugin contribution tier asked directly, with doubles for the registry and its plugins so that each gate is
# seen by what it lets through. That `MethodDispatcher.resolve_site` asks the tier, and what it records after an
# answer, is `method_dispatcher_spec.rb`'s "plugin dynamic_return contribution tier"; real plugins through the
# registry are `spec/rigor/plugin/contribution_index_spec.rb`'s.
RSpec.describe Rigor::Inference::MethodDispatcher::PluginContribution do
  let(:call_node) { Prism.parse("recv.foo").value.statements.body.first }
  let(:receiver) { Rigor::Type::Combinator.nominal_of("Widget") }
  let(:string) { Rigor::Type::Combinator.nominal_of("String") }
  let(:index) do
    instance_double(Rigor::Plugin::ContributionIndex,
                    for_method_dispatch: plugins, dispatch_candidate?: true, dynamic_candidate_for?: true)
  end
  let(:registry) { instance_double(Rigor::Plugin::Registry, empty?: false, contribution_index: index) }
  let(:scope) { instance_double(Rigor::Scope, environment: instance_double(Rigor::Environment, plugin_registry: registry)) }
  let(:plugins) { [plugin_answering(string)] }

  def plugin_answering(type)
    instance_double(Rigor::Plugin::Base, dynamic_return_answer: type)
  end

  def site(node: call_node, in_scope: scope)
    cc(receiver: receiver, method_name: :foo, args: [], call_node: node, scope: in_scope)
  end

  describe ".try_dispatch" do
    it "answers the plugin's return type, asked with the site's call node, scope and receiver" do
      expect(described_class.try_dispatch(site)).to eq(string)
      expect(plugins.first).to have_received(:dynamic_return_answer)
        .with(call_node: call_node, scope: scope, receiver_type: receiver)
    end

    it "merges what several plugins answer, each asked in registry order" do
      integer = Rigor::Type::Combinator.nominal_of("Integer")
      plugins.push(plugin_answering(nil), plugin_answering(integer))

      merged = Rigor::FlowContribution::Merger.merge(
        [string, integer].map { |type| Rigor::FlowContribution.new(return_type: type) }
      ).return_type
      expect(described_class.try_dispatch(site)).to eq(merged)
      expect(plugins).to all(have_received(:dynamic_return_answer).once)
    end

    # Issue #3322 — an answer through `Plugin::Base#optimistic_nil_free` types the call as the wrapped type and
    # records the optimistic mark on the call node; a plain answer records none.
    it "unwraps an optimistic answer and records the plugin nil-free mark on the call node" do
      plugins.replace([plugin_answering(Rigor::Plugin::OptimisticReturn.new(type: string))])
      allow(scope).to receive(:record_optimistic_origin)

      expect(described_class.try_dispatch(site)).to eq(string)
      expect(scope).to have_received(:record_optimistic_origin)
        .with(call_node, Rigor::Inference::OptimisticOrigin::PLUGIN_NIL_FREE)
    end

    it "records no mark for a plain answer" do
      allow(scope).to receive(:record_optimistic_origin)

      described_class.try_dispatch(site)
      expect(scope).not_to have_received(:record_optimistic_origin)
    end

    it "declines when no plugin answers, with nothing to merge" do
      plugins.replace([plugin_answering(nil)])
      allow(Rigor::FlowContribution::Merger).to receive(:merge).and_call_original

      expect(described_class.try_dispatch(site)).to be_nil
      expect(Rigor::FlowContribution::Merger).not_to have_received(:merge)
    end

    it "declines a site without a call node, asking no plugin" do
      expect(described_class.try_dispatch(site(node: nil))).to be_nil
      expect(plugins.first).not_to have_received(:dynamic_return_answer)
    end

    it "declines a site without a scope" do
      expect(described_class.try_dispatch(site(in_scope: nil))).to be_nil
    end

    it "declines when the scope's environment is nil or carries no registry" do
      no_registry = instance_double(Rigor::Scope,
                                    environment: instance_double(Rigor::Environment, plugin_registry: nil))

      expect(described_class.try_dispatch(site(in_scope: instance_double(Rigor::Scope, environment: nil)))).to be_nil
      expect(described_class.try_dispatch(site(in_scope: no_registry))).to be_nil
    end

    it "declines an empty registry without compiling its index" do
      allow(registry).to receive(:empty?).and_return(true)

      expect(described_class.try_dispatch(site)).to be_nil
      expect(registry).not_to have_received(:contribution_index)
    end
  end

  describe "the gates ahead of a plugin" do
    it "asks the global gate with the call's name, and no plugin when it says no" do
      allow(index).to receive(:dispatch_candidate?).with(:foo).and_return(false)

      expect(described_class.try_dispatch(site)).to be_nil
      expect(plugins.first).not_to have_received(:dynamic_return_answer)
    end

    it "asks the global gate with nil for a call node that has no name" do
      block_argument = Prism.parse("recv.foo(&:bar)").value.statements.body.first.block
      allow(index).to receive(:dispatch_candidate?).with(nil).and_return(false)

      expect(described_class.try_dispatch(site(node: block_argument))).to be_nil
      expect(index).to have_received(:dispatch_candidate?).with(nil)
    end

    it "skips a plugin its own gate turns away and still asks the next" do
      gated = plugin_answering(Rigor::Type::Combinator.nominal_of("Integer"))
      plugins.unshift(gated)
      allow(index).to receive(:dynamic_candidate_for?).with(gated, :foo).and_return(false)

      expect(described_class.try_dispatch(site)).to eq(string)
      expect(gated).not_to have_received(:dynamic_return_answer)
    end

    it "does not consult the gates when no plugin declares a dynamic_return" do
      plugins.clear

      expect(described_class.try_dispatch(site)).to be_nil
      expect(index).not_to have_received(:dispatch_candidate?)
    end

    it "drops a plugin that raises and keeps what the others answer" do
      raising = instance_double(Rigor::Plugin::Base)
      allow(raising).to receive(:dynamic_return_answer).and_raise("boom")
      plugins.unshift(raising)

      expect(described_class.try_dispatch(site)).to eq(string)
    end
  end

  # The second entry: `MethodDispatcher.plugin_member_answers?` holds a call node, a scope and the call's own `self`,
  # and no `CallContext`.
  describe ".merged_return_type" do
    it "answers for a call node, a scope and a receiver type, in that order" do
      expect(described_class.merged_return_type(call_node, scope, receiver)).to eq(string)
      expect(plugins.first).to have_received(:dynamic_return_answer)
        .with(call_node: call_node, scope: scope, receiver_type: receiver)
    end

    it "is what MethodDispatcher.plugin_member_answers? asks first" do
      dispatcher = Rigor::Inference::MethodDispatcher
      asked = { call_node: call_node, scope: scope, receiver_type: receiver, method_name: :foo }

      expect(dispatcher.plugin_member_answers?(**asked)).to be(true)
      expect(plugins.first).to have_received(:dynamic_return_answer)
        .with(call_node: call_node, scope: scope, receiver_type: receiver)
    end
  end
end
