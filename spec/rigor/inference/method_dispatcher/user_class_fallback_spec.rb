# frozen_string_literal: true

require "spec_helper"

# The user-class ancestor fallback asked directly, on the default environment and on scopes whose discovery tables
# are written by hand. It reads the receiver, the selector, the environment, the call node and the scope of the
# context. That `MethodDispatcher.resolve_site` asks it, and the origin it records after a `Dynamic` answer, is
# `method_dispatcher_spec.rb`'s ("user-class fallback for module-mixin receivers", "private-method suppression on the
# explicit-receiver fallback") and `composite_receiver_spec.rb`'s positive control; the two declines on a scope are
# measured end to end in `spec/integration/singleton_override_of_module_method_spec.rb` and
# `spec/integration/fixtures/core_subclass_kernel_shadow.rb`.
RSpec.describe Rigor::Inference::MethodDispatcher::UserClassFallback do
  def comb = Rigor::Type::Combinator

  def rbs_dispatch = Rigor::Inference::MethodDispatcher::RbsDispatch

  let(:environment) { Rigor::Environment.default }
  let(:widget) { comb.nominal_of("ProjectOnlyWidget") }
  let(:widget_class) { comb.singleton_of("ProjectOnlyWidget") }
  let(:string) { comb.nominal_of("String") }

  # Both memos are per-thread slots keyed on the identity of the discovery index, and every scope without a discovery
  # table shares one index, so an example starts with neither holding another example's answers.
  around do |example|
    clear_memos
    example.run
  ensure
    clear_memos
  end

  def clear_memos
    set_typing_slot(:user_class_fallback_external_ancestor, nil)
    set_typing_slot(:user_class_fallback_defines_name, nil)
  end

  def call_node(source) = Prism.parse(source).value.statements.body.first

  def site(receiver, name, args: [], **rest)
    cc(receiver: receiver, method_name: name, args: args, environment: environment, **rest)
  end

  def ask(receiver, name, **) = described_class.try_dispatch(site(receiver, name, **))

  # A scope whose project source records `methods` (`{ class name => { method name => side } }`), writes the
  # `superclasses` (`{ class name => superclass name }`) and holds a `def self.<name>` body for each
  # `[class name, method name]` of `singleton_defs`.
  def scope_defining(methods, superclasses: {}, singleton_defs: [])
    empty = Rigor::Scope.empty(environment: environment)
    index = empty.discovery
    nodes = singleton_defs.group_by(&:first).transform_values do |rows|
      rows.to_h { |_, name| [name, Prism.parse("def self.#{name} = 1").value.statements.body.first] }
    end
    empty.with_discovery(
      index.with(discovered_methods: methods, possible_discovered_methods: index.possible_discovered_methods,
                 discovered_superclasses: superclasses, discovered_singleton_def_nodes: nodes,
                 contested_discovered_singleton_def_nodes: index.contested_discovered_singleton_def_nodes)
    )
  end

  describe ".try_dispatch" do
    it "answers an instance of a class RBS does not know from Object" do
      expect(ask(widget, :to_s)).to eq(string)
    end

    it "answers the class object of a class RBS does not know from Class" do
      expect(ask(widget_class, :name)).to eq(string)
    end

    # A mixin-only module sees `Object`'s methods through whichever class includes it.
    it "answers an instance of a module RBS knows from Object" do
      expect(ask(comb.nominal_of("Comparable"), :inspect)).to eq(string)
    end

    it "declines a class RBS knows, its class object and a known module's, without asking RbsDispatch" do
      allow(rbs_dispatch).to receive(:try_dispatch)

      expect(ask(string, :to_s)).to be_nil
      expect(ask(comb.singleton_of("String"), :name)).to be_nil
      expect(ask(comb.singleton_of("Comparable"), :name)).to be_nil
      expect(rbs_dispatch).not_to have_received(:try_dispatch)
    end

    it "declines a receiver that names no class" do
      expect(ask(comb.constant_of(1), :to_s)).to be_nil
      expect(ask(comb.untyped, :to_s)).to be_nil
      expect(ask(comb.union(widget, widget_class), :to_s)).to be_nil
    end

    it "declines without an environment" do
      expect(described_class.try_dispatch(cc(receiver: widget, method_name: :to_s, args: []))).to be_nil
    end

    it "declines a name Object does not declare" do
      expect(ask(widget, :no_such_method)).to be_nil
    end

    # `Kernel#dup` is `-> self`: the receiver the site named, not the `Object` the lookup was routed through.
    it "keeps the site's receiver as `self`" do
      expect(ask(widget, :dup)).to eq(widget)
    end

    it "asks RbsDispatch on the fallback receiver, with the site's receiver as `self` and no call node or scope" do
      asked = []
      allow(rbs_dispatch).to receive(:try_dispatch) { |context| asked << context and string }
      scope = Rigor::Scope.empty(environment: environment)
      block = comb.nominal_of("Proc")

      answer = ask(widget, :tap, args: [string], block_type: block, call_node: call_node("w.tap(1)"), scope: scope)

      expect(answer).to equal(string)
      expect(asked).to eq(
        [cc(receiver: comb.nominal_of("Object"), method_name: :tap, args: [string], block_type: block,
            environment: environment, self_type_override: widget, public_only: true)]
      )
    end
  end

  # Ruby raises NoMethodError for a private method called on an explicit receiver, so `Favourite.select(:id)` must
  # not read as the private `Kernel#select`.
  describe "a private method of Object or Class" do
    let(:strings) { comb.nominal_of("Array", type_args: [string]) }

    it "does not answer on an explicit receiver" do
      expect(ask(widget_class, :select, call_node: call_node("ProjectOnlyWidget.select(:id)"))).to be_nil
      expect(ask(widget, :select, call_node: call_node("widget.select"))).to be_nil
    end

    it "answers on `self`, with no receiver, and when the site has no call node" do
      expect(ask(widget, :select, call_node: call_node("self.select"))).to eq(strings)
      expect(ask(widget, :select, call_node: call_node("select"))).to eq(strings)
      expect(ask(widget, :select)).to eq(strings)
    end

    it "answers a public method on an explicit receiver" do
      expect(ask(widget, :to_s, call_node: call_node("widget.to_s"))).to eq(string)
    end
  end

  # Issue #2196 — `class FL < Array` answers `select` from `Array`, never from the private `Kernel#select`.
  describe "a name a core or stdlib ancestor of the class declares" do
    let(:list) { comb.nominal_of("FieldList") }
    let(:scope) { scope_defining({ "FieldList" => { add: :instance } }, superclasses: { "FieldList" => "Array" }) }
    let(:resolution) { Rigor::Inference::ExternalAncestorResolution }

    it "declines the name, and answers one only Object or Kernel declares" do
      expect(ask(list, :select, scope: scope)).to be_nil
      expect(ask(list, :puts, scope: scope)).to eq(comb.constant_of(nil))
    end

    it "does not walk the ancestry without a scope, nor for a class object" do
      allow(resolution).to receive(:resolve)

      expect(ask(list, :select)).to eq(comb.nominal_of("Array", type_args: [string]))
      expect(ask(comb.singleton_of("FieldList"), :select, scope: scope))
        .to eq(comb.nominal_of("Array", type_args: [string]))
      expect(resolution).not_to have_received(:resolve)
    end

    it "asks the walk for the instance side, with the scope and the environment, filing no dependency" do
      allow(resolution).to receive(:resolve).and_call_original

      ask(list, :select, scope: scope)

      expect(resolution).to have_received(:resolve)
        .with("FieldList", :select, :instance, scope: scope, environment: environment, record_dependencies: false)
    end

    it "walks once for a class and a name, and again for another name" do
      allow(resolution).to receive(:resolve).and_call_original

      2.times { expect(ask(list, :select, scope: scope)).to be_nil }
      expect(resolution).to have_received(:resolve).once
      ask(list, :first, scope: scope)
      expect(resolution).to have_received(:resolve).twice
    end

    it "keeps the answers in one slot for the scope's discovery index and the environment" do
      ask(list, :select, scope: scope)
      ask(list, :puts, scope: scope)

      discovery, kept_environment, answers = typing_slot(:user_class_fallback_external_ancestor)
      expect(discovery).to equal(scope.discovery)
      expect(kept_environment).to equal(environment)
      expect(answers).to eq({ ["FieldList", :select] => true, ["FieldList", :puts] => false })
    end

    it "starts a fresh slot for another discovery index or another environment" do
      other_scope = scope_defining({ "FieldList" => { add: :instance } })
      other_environment = Rigor::Environment.for_project

      ask(list, :select, scope: scope)
      expect(ask(list, :select, scope: other_scope)).to eq(comb.nominal_of("Array", type_args: [string]))
      expect(typing_slot(:user_class_fallback_external_ancestor).first).to equal(other_scope.discovery)

      ask(list, :select, scope: scope)
      described_class.try_dispatch(cc(receiver: list, method_name: :select, args: [], environment: other_environment,
                                      scope: scope))
      expect(typing_slot(:user_class_fallback_external_ancestor)[1]).to equal(other_environment)
    end

    # An audit recomputation runs with every memo bypassed, so it reads no stored answer and stores none.
    it "neither reads nor writes the memo while the memo audit is suspended" do
      ask(list, :select, scope: scope)
      allow(resolution).to receive(:resolve).and_return(nil)
      Rigor::MemoAudit.enable!

      suspended = Rigor::MemoAudit.suspended { [ask(list, :select, scope: scope), ask(list, :first, scope: scope)] }

      expect(suspended).to eq([comb.nominal_of("Array", type_args: [string]), nil])
      expect(typing_slot(:user_class_fallback_external_ancestor).last).to eq({ ["FieldList", :select] => true })
    ensure
      Rigor::MemoAudit.disable!
    end
  end

  # Issue #2284 — a class object answers a name from a project definer on its singleton chain ahead of `Class`.
  describe "a class object whose singleton chain holds a project definer of the name" do
    let(:scope) { scope_defining({ "ProjectOnlyWidget" => { render: :instance } }, singleton_defs: [definer]) }
    let(:definer) { ["ProjectOnlyWidget", :name] }
    let(:timing) { Rigor::Inference::BlockCallTiming }
    let(:symbols) { comb.nominal_of("Array", type_args: [comb.nominal_of("Symbol")]) }

    it "declines the name, and answers a name no project file defines" do
      expect(ask(widget_class, :name, scope: scope)).to be_nil
      expect(ask(widget_class, :instance_methods, scope: scope)).to eq(symbols)
    end

    it "answers the name for a class whose chain holds no definer of it" do
      gadget_class = comb.singleton_of("ProjectOnlyGadget")

      expect(ask(gadget_class, :name, scope: scope)).to eq(string)
    end

    it "answers without a scope, and does not ask for an instance" do
      instance_scope = scope_defining({}, singleton_defs: [["ProjectOnlyWidget", :to_s]])

      expect(ask(widget_class, :name)).to eq(string)
      expect(ask(widget, :to_s, scope: instance_scope)).to eq(string)
      expect(ask(widget_class, :to_s, scope: instance_scope)).to be_nil
    end

    it "does not walk the chain for a name no project file defines" do
      chain = Rigor::Scope::ResolutionChain
      allow(chain).to receive(:for).and_call_original

      ask(widget_class, :instance_methods, scope: scope)
      expect(chain).not_to have_received(:for)
      ask(widget_class, :name, scope: scope)
      expect(chain).to have_received(:for).with(scope, "ProjectOnlyWidget", :singleton, :methods)
    end

    it "reads the project's tables once for a name, and again for another name" do
      allow(timing).to receive(:project_defines_anywhere?).and_call_original

      2.times { ask(widget_class, :name, scope: scope) }
      expect(timing).to have_received(:project_defines_anywhere?).with(:name, scope).once
      ask(widget_class, :instance_methods, scope: scope)
      expect(timing).to have_received(:project_defines_anywhere?).twice
    end

    it "keeps the answers in one slot for the scope's discovery index and its environment" do
      ask(widget_class, :name, scope: scope)
      ask(widget_class, :instance_methods, scope: scope)

      discovery, kept_environment, answers = typing_slot(:user_class_fallback_defines_name)
      expect(discovery).to equal(scope.discovery)
      expect(kept_environment).to equal(environment)
      expect(answers).to eq({ name: true, instance_methods: false })
    end

    it "starts a fresh slot for another discovery index or another environment" do
      other_scope = scope_defining({})
      other_environment = Rigor::Environment.for_project

      ask(widget_class, :name, scope: scope)
      ask(widget_class, :name, scope: other_scope)
      expect(typing_slot(:user_class_fallback_defines_name).first).to equal(other_scope.discovery)
      expect(typing_slot(:user_class_fallback_defines_name).last).to eq({ name: false })

      ask(widget_class, :name, scope: scope)
      described_class.try_dispatch(
        cc(receiver: widget_class, method_name: :name, args: [], environment: other_environment,
           scope: Rigor::Scope.empty(environment: other_environment).with_discovery(scope.discovery))
      )
      expect(typing_slot(:user_class_fallback_defines_name)[1]).to equal(other_environment)
    end

    # Issue #1459 — the `defines:<name>` edge is filed on every ask, a memo hit included.
    it "files the `defines` edge on a memo hit as on a miss" do
      recorder = Rigor::Analysis::DependencyRecorder
      miss = recorder.record_for("app/reader.rb") { ask(widget_class, :name, scope: scope) }
      hit = recorder.record_for("app/reader.rb") { ask(widget_class, :name, scope: scope) }

      expect(miss.missing).to include("defines:name")
      expect(hit.missing).to include("defines:name")
    end

    it "neither reads nor writes the memo while the memo audit is suspended" do
      ask(widget_class, :name, scope: scope)
      allow(timing).to receive(:project_defines_anywhere?).and_return(false)
      Rigor::MemoAudit.enable!

      suspended = Rigor::MemoAudit.suspended do
        [ask(widget_class, :name, scope: scope), ask(widget_class, :hash, scope: scope)]
      end

      expect(suspended).to eq([string, comb.nominal_of("Integer")])
      expect(typing_slot(:user_class_fallback_defines_name).last).to eq({ name: true })
    ensure
      Rigor::MemoAudit.disable!
    end
  end

  describe ".user_class_fallback_receiver" do
    it "is Object for an instance of an unknown class or of a known module, and Class for an unknown class object" do
      object = environment.nominal_for_name("Object")

      expect(described_class.user_class_fallback_receiver(widget, environment)).to eq(object)
      expect(described_class.user_class_fallback_receiver(comb.nominal_of("Comparable"), environment)).to eq(object)
      expect(described_class.user_class_fallback_receiver(widget_class, environment))
        .to eq(environment.singleton_for_name("Class"))
    end

    it "is nil for a known class, a known class object and any other carrier" do
      expect(described_class.user_class_fallback_receiver(string, environment)).to be_nil
      expect(described_class.user_class_fallback_receiver(comb.singleton_of("String"), environment)).to be_nil
      expect(described_class.user_class_fallback_receiver(comb.constant_of(1), environment)).to be_nil
    end
  end
end
