# frozen_string_literal: true

require "spec_helper"

# The dependency-source tier asked directly, on a real `DependencySourceInference::Index`. It reads the receiver,
# the selector and the environment of the context and nothing else. That `MethodDispatcher.resolve_site` asks it,
# and the origin it records after an answer, is `method_dispatcher_spec.rb`'s "dependency-source inference tier".
RSpec.describe Rigor::Inference::MethodDispatcher::DependencySource do
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:widget) { Rigor::Type::Combinator.nominal_of("FakeLib::Widget") }
  let(:widget_class) { Rigor::Type::Combinator.singleton_of("FakeLib::Widget") }
  let(:inference) { Rigor::Analysis::DependencySourceInference }
  let(:fake_gem) do
    inference::GemResolver::Resolved.new(
      gem_name: "fake", version: "1.0.0", gem_dir: "/fake", mode: :when_missing, roots: %w[lib]
    )
  end

  def index_of(method_catalog, **)
    inference::Index.new(resolved_gems: [fake_gem], method_catalog: method_catalog, **)
  end

  def environment_with(index, plugin_registry: nil)
    instance_double(Rigor::Environment, dependency_source_index: index, plugin_registry: plugin_registry)
  end

  def dispatch(receiver, method_name, environment)
    described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: [], environment: environment))
  end

  describe ".try_dispatch" do
    it "answers Dynamic[top] for a catalogued method of an instance or of the class object" do
      environment = environment_with(index_of({ ["FakeLib::Widget", :render] => :instance }))

      expect(dispatch(widget, :render, environment)).to eq(untyped)
      expect(dispatch(widget_class, :render, environment)).to eq(untyped)
    end

    it "wraps the return type the catalog recovered in Dynamic" do
      forty_two = Rigor::Type::Combinator.constant_of(42)
      entry = inference::Walker::CatalogEntry.new(kind: :instance, return_type: forty_two)
      environment = environment_with(index_of({ ["FakeLib::Widget", :version] => entry }))

      expect(dispatch(widget, :version, environment)).to eq(Rigor::Type::Combinator.dynamic(forty_two))
    end

    it "declines a method or a class the catalog does not hold, and a receiver that names no class" do
      environment = environment_with(index_of({ ["FakeLib::Widget", :render] => :instance }))

      expect(dispatch(widget, :missing, environment)).to be_nil
      expect(dispatch(Rigor::Type::Combinator.nominal_of("Other"), :render, environment)).to be_nil
      expect(dispatch(Rigor::Type::Combinator.constant_of(1), :render, environment)).to be_nil
    end

    it "declines without an environment and without an index" do
      expect(dispatch(widget, :render, nil)).to be_nil
      expect(dispatch(widget, :render, environment_with(nil))).to be_nil
    end

    it "declines an index that resolved no gem without reading its catalog" do
      index = inference::Index.new(method_catalog: { ["FakeLib::Widget", :render] => :instance })

      expect(dispatch(widget, :render, environment_with(index))).to be_nil
    end

    # ADR-10 5a: a plugin that owns the receiver is the authority for it, catalogued method or not.
    it "declines a receiver a plugin owns" do
      contribution_index = instance_double(Rigor::Plugin::ContributionIndex)
      registry = instance_double(Rigor::Plugin::Registry, empty?: false, contribution_index: contribution_index)
      environment = environment_with(index_of({ ["FakeLib::Widget", :render] => :instance }), plugin_registry: registry)
      allow(contribution_index).to receive(:owns_receiver?).with("FakeLib::Widget", environment).and_return(true)

      expect(dispatch(widget, :render, environment)).to be_nil
    end
  end

  # ADR-10 5b: under `:dependency_silence`, a class of a gem whose walk hit its cap answers Dynamic[top] for a method
  # the catalog never reached.
  describe "a catalog miss on a budget-exceeded gem" do
    def silenced(strategy: :dependency_silence, exceeded: ["fake"], owners: { "FakeLib::Widget" => "fake" })
      environment_with(
        index_of({}, budget_overrun_strategy: strategy, budget_exceeded: exceeded, class_to_gem: owners)
      )
    end

    it "answers Dynamic[top] under `:dependency_silence`" do
      expect(dispatch(widget, :uncatalogued, silenced)).to eq(untyped)
    end

    it "declines under the default strategy" do
      expect(dispatch(widget, :uncatalogued, silenced(strategy: :walker_cap))).to be_nil
    end

    it "declines a class no opted-in gem owns" do
      expect(dispatch(widget, :uncatalogued, silenced(owners: {}))).to be_nil
    end

    it "declines a class of a gem that stayed within its budget" do
      expect(dispatch(widget, :uncatalogued, silenced(exceeded: ["other"]))).to be_nil
    end
  end

  describe ".plugin_owns_receiver?" do
    it "is false without an environment, without a registry, and for an empty registry" do
      empty = instance_double(Rigor::Plugin::Registry, empty?: true)

      expect(described_class.plugin_owns_receiver?("FakeLib::Widget", nil)).to be(false)
      expect(described_class.plugin_owns_receiver?("FakeLib::Widget", environment_with(nil))).to be(false)
      expect(described_class.plugin_owns_receiver?("FakeLib::Widget", environment_with(nil, plugin_registry: empty)))
        .to be(false)
    end

    it "answers what the registry's contribution index answers for the class and the environment" do
      contribution_index = instance_double(Rigor::Plugin::ContributionIndex)
      registry = instance_double(Rigor::Plugin::Registry, empty?: false, contribution_index: contribution_index)
      environment = environment_with(nil, plugin_registry: registry)
      allow(contribution_index).to receive(:owns_receiver?).with("FakeLib::Widget", environment).and_return(true)
      allow(contribution_index).to receive(:owns_receiver?).with("Other", environment).and_return(false)

      expect(described_class.plugin_owns_receiver?("FakeLib::Widget", environment)).to be(true)
      expect(described_class.plugin_owns_receiver?("Other", environment)).to be(false)
    end
  end

  # The second entry: the boundary-cross record `MethodDispatcher.resolve_site` makes after an RBS answer reads
  # the receiver's class the same way.
  describe ".dep_source_class_name" do
    it "names the class of an instance and of a class object, and nothing else" do
      expect(described_class.dep_source_class_name(widget)).to eq("FakeLib::Widget")
      expect(described_class.dep_source_class_name(widget_class)).to eq("FakeLib::Widget")
      expect(described_class.dep_source_class_name(Rigor::Type::Combinator.constant_of(1))).to be_nil
      expect(described_class.dep_source_class_name(untyped)).to be_nil
    end
  end
end
