# frozen_string_literal: true

require "spec_helper"

# The discovered-method tier asked directly, on a real scope whose discovery tables are written by hand. It reads the
# receiver, the selector and the scope of the context and nothing else. That `MethodDispatcher.resolve` asks it, and
# where among the other tiers, is `method_dispatcher_spec.rb`'s "the order of the … tiers"; the last group here is
# what holds the tier's two callers to it.
RSpec.describe Rigor::Inference::MethodDispatcher::DiscoveredMethod do
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:widget) { Rigor::Type::Combinator.nominal_of("Widget") }
  let(:widget_class) { Rigor::Type::Combinator.singleton_of("Widget") }
  let(:environment) { Rigor::Environment.default }

  def def_node(name) = Prism.parse("def #{name} = 1").value.statements.body.first

  # A scope whose project source records `methods` (`{ class name => { method name => side } }`) in the method table
  # and holds a re-typable body for each `[class name, method name]` of `instance_defs` and `singleton_defs`.
  def scope_defining(methods, instance_defs: [], singleton_defs: [])
    empty = Rigor::Scope.empty(environment: environment)
    index = empty.discovery
    nodes = lambda { |pairs|
      pairs.group_by(&:first).transform_values do |rows|
        rows.to_h do |_, name|
          [name, def_node(name)]
        end
      end
    }
    empty.with_discovery(
      index.with(discovered_methods: methods, possible_discovered_methods: index.possible_discovered_methods,
                 discovered_def_nodes: nodes.call(instance_defs),
                 contested_discovered_def_nodes: index.contested_discovered_def_nodes,
                 discovered_singleton_def_nodes: nodes.call(singleton_defs),
                 contested_discovered_singleton_def_nodes: index.contested_discovered_singleton_def_nodes)
    )
  end

  def dispatch(receiver, method_name, scope)
    described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: [], scope: scope))
  end

  describe ".try_dispatch" do
    it "answers Dynamic[top] for a method the table records on the receiver's side and no body is held for" do
      scope = scope_defining({ "Widget" => { render: :instance, build: :singleton } })

      expect(dispatch(widget, :render, scope)).to eq(untyped)
      expect(dispatch(widget_class, :build, scope)).to eq(untyped)
    end

    it "declines a method the table records on the other side, a name it does not hold, and another class" do
      scope = scope_defining({ "Widget" => { render: :instance, build: :singleton } })

      expect(dispatch(widget_class, :render, scope)).to be_nil
      expect(dispatch(widget, :build, scope)).to be_nil
      expect(dispatch(widget, :missing, scope)).to be_nil
      expect(dispatch(Rigor::Type::Combinator.nominal_of("Gadget"), :render, scope)).to be_nil
    end

    it "declines without a scope" do
      expect(dispatch(widget, :render, nil)).to be_nil
    end

    it "declines a receiver that names no class without reading the table" do
      scope = instance_double(Rigor::Scope, discovered_method?: true, user_def_for: nil, singleton_def_for: nil)

      expect(dispatch(Rigor::Type::Combinator.constant_of(1), :render, scope)).to be_nil
      expect(dispatch(untyped, :render, scope)).to be_nil
      expect(dispatch(Rigor::Type::Combinator.union(widget, widget_class), :render, scope)).to be_nil
      expect(scope).not_to have_received(:discovered_method?)
    end

    # The typer's user-method inference re-types a body the scope holds, so the tier leaves the call to it.
    it "declines an instance method the scope holds a body for, and a singleton method likewise" do
      scope = scope_defining({ "Widget" => { render: :instance, build: :singleton } },
                             instance_defs: [["Widget", :render]],
                             singleton_defs: [["Widget", :build]])

      expect(dispatch(widget, :render, scope)).to be_nil
      expect(dispatch(widget_class, :build, scope)).to be_nil
    end

    it "reads the body table of the receiver's side only" do
      scope = scope_defining({ "Widget" => { both: Rigor::Scope::DiscoveryIndex::METHOD_KIND_BOTH } },
                             singleton_defs: [["Widget", :both]])
      other = scope_defining({ "Widget" => { both: Rigor::Scope::DiscoveryIndex::METHOD_KIND_BOTH } },
                             instance_defs: [["Widget", :both]])

      expect(dispatch(widget, :both, scope)).to eq(untyped)
      expect(dispatch(widget_class, :both, scope)).to be_nil
      expect(dispatch(widget_class, :both, other)).to eq(untyped)
      expect(dispatch(widget, :both, other)).to be_nil
    end
  end

  # The second entry: `MethodDispatcher.record_transitive_void_origin` keys the same table the same way.
  describe ".discovered_method_lookup" do
    def member_carriers
      comb = Rigor::Type::Combinator
      typed = { x: comb.nominal_of("Integer") }
      [comb.struct_instance_of(members: typed, class_name: "Line"),
       comb.data_instance_of(members: typed, class_name: "Line"),
       comb.struct_class_of(members: [:x], class_name: "Line"), comb.data_class_of(members: [:x], class_name: "Line")]
    end

    it "names the class and the instance side for an instance, a Struct instance and a Data instance" do
      struct_instance, data_instance, = member_carriers

      expect(described_class.discovered_method_lookup(widget)).to eq(["Widget", :instance])
      expect(described_class.discovered_method_lookup(struct_instance)).to eq(["Line", :instance])
      expect(described_class.discovered_method_lookup(data_instance)).to eq(["Line", :instance])
    end

    it "names the class and the singleton side for a class object, a Struct class and a Data class" do
      _, _, struct_class, data_class = member_carriers

      expect(described_class.discovered_method_lookup(widget_class)).to eq(["Widget", :singleton])
      expect(described_class.discovered_method_lookup(struct_class)).to eq(["Line", :singleton])
      expect(described_class.discovered_method_lookup(data_class)).to eq(["Line", :singleton])
    end

    it "answers the one shared, frozen pair of nils for any other carrier" do
      constant = described_class.discovered_method_lookup(Rigor::Type::Combinator.constant_of(1))

      expect(constant).to eq([nil, nil]).and be_frozen
      expect(described_class.discovered_method_lookup(untyped)).to equal(constant)
      expect(described_class.discovered_method_lookup(nil)).to equal(constant)
    end
  end

  describe "its two callers in MethodDispatcher" do
    let(:dispatcher) { Rigor::Inference::MethodDispatcher }
    let(:call_node) { Prism.parse("widget.render").value.statements.body.first }

    it "is the tier `resolve` asks for a class RBS does not know, and the origin of its answer is recorded" do
      scope = scope_defining({ "Widget" => { render: :instance } })

      answer = dispatcher.dispatch(receiver_type: widget, method_name: :render, arg_types: [],
                                   environment: environment, call_node: call_node, scope: scope)

      expect(answer).to eq(untyped)
      expect(scope.dynamic_origin(call_node)).to eq(Rigor::Inference::DynamicOrigin::INFERRED_RETURN_UNTYPED)
    end

    it "is the lookup the transitive-void record keys the scope's tables by" do
      scope = scope_defining({ "Widget" => { render: :instance } })
      allow(described_class).to receive(:discovered_method_lookup).and_call_original

      dispatcher.record_transitive_void_origin(widget, :render, call_node, scope)

      expect(described_class).to have_received(:discovered_method_lookup).with(widget)
    end
  end
end
