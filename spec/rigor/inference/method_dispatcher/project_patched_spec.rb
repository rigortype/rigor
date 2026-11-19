# frozen_string_literal: true

require "spec_helper"

# The project-patched tier asked directly, on a real `ProjectPatchedMethods` registry.
# `MethodDispatcher.resolve_site` asks it twice, and what it records after each answer and where each question sits
# among the other tiers is `method_dispatcher_spec.rb`'s ("project-side patched-method tier", "a `pre_eval:` alias …",
# "a `pre_eval:` patch on an ancestor"); the registry's own lookups are `project_patched_methods_spec.rb`'s.
RSpec.describe Rigor::Inference::MethodDispatcher::ProjectPatched do
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:integer) { Rigor::Type::Combinator.nominal_of("Integer") }
  let(:integer_class) { Rigor::Type::Combinator.singleton_of("Integer") }
  let(:dispatcher) { Rigor::Inference::MethodDispatcher }

  def patch(class_name, name, value = nil, kind: :instance, **rest)
    Rigor::Inference::ProjectPatchedMethods::Entry.new(
      class_name: class_name, method_name: name, kind: kind, source_path: "ext/core.rb", source_line: 1,
      return_type: value && Rigor::Type::Combinator.constant_of(value), **rest
    )
  end

  def patched(value) = Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.constant_of(value))

  def environment_with(*entries)
    Rigor::Environment.for_project(
      project_patched_methods: Rigor::Inference::ProjectPatchedMethods.new(entries: entries)
    )
  end

  def call_node(source) = Prism.parse(source).value.statements.body.first

  def site(receiver, name, environment, **rest)
    cc(receiver: receiver, method_name: name, args: [], environment: environment, **rest)
  end

  describe ".try_dispatch for the receiver's own class" do
    it "answers Dynamic of the patch's return type, and Dynamic[top] for a patch without one" do
      environment = environment_with(patch("Integer", :typed, :own), patch("Integer", :bare))

      expect(described_class.try_dispatch(site(integer, :typed, environment))).to eq(patched(:own))
      expect(described_class.try_dispatch(site(integer, :bare, environment))).to eq(untyped)
    end

    it "reads the singleton side for a class object and the instance side for an instance" do
      environment = environment_with(patch("Integer", :build, :class_side, kind: :singleton),
                                     patch("Integer", :twice, :instance_side))

      expect(described_class.try_dispatch(site(integer_class, :build, environment))).to eq(patched(:class_side))
      expect(described_class.try_dispatch(site(integer, :build, environment))).to be_nil
      expect(described_class.try_dispatch(site(integer_class, :twice, environment))).to be_nil
    end

    it "declines a name no patch defines, and does not search the ancestors unless asked" do
      environment = environment_with(patch("Object", :zz, :object))

      expect(described_class.try_dispatch(site(integer, :missing, environment))).to be_nil
      expect(described_class.try_dispatch(site(integer, :zz, environment))).to be_nil
    end

    it "declines without an environment and without a registry" do
      no_registry = instance_double(Rigor::Environment, project_patched_methods: nil)

      expect(described_class.try_dispatch(site(integer, :typed, nil))).to be_nil
      expect(described_class.try_dispatch(site(integer, :typed, no_registry))).to be_nil
    end

    it "declines an empty registry, and a receiver that names no class, without a lookup" do
      registry = instance_double(Rigor::Inference::ProjectPatchedMethods, empty?: true, lookup: nil)
      environment = instance_double(Rigor::Environment, project_patched_methods: registry)

      expect(described_class.try_dispatch(site(integer, :typed, environment))).to be_nil
      allow(registry).to receive(:empty?).and_return(false)
      expect(described_class.try_dispatch(site(Rigor::Type::Combinator.constant_of(1), :typed, environment))).to be_nil
      expect(registry).not_to have_received(:lookup)
    end
  end

  # Ruby 4.0.5: `1.ip` raises NoMethodError under `class Integer; private def ip`, and `self.ip` and a bare `ip` run.
  describe "a patch Ruby would not let the call reach" do
    let(:environment) do
      environment_with(patch("Integer", :ip, :own, visibility: :private),
                       patch("Numeric", :np, :numeric, visibility: :protected))
    end
    let(:top_level) { Rigor::Scope.empty(environment: environment) }

    def ask(name, source, **rest)
      described_class.try_dispatch(site(integer, name, environment, call_node: call_node(source), **rest),
                                   through_ancestors: true)
    end

    it "does not answer a private patch on an explicit receiver" do
      expect(ask(:ip, "1.ip", scope: top_level)).to be_nil
    end

    it "answers a private patch on `self`, with no receiver, and when the site has no call node" do
      expect([ask(:ip, "self.ip", scope: top_level), ask(:ip, "ip", scope: top_level)]).to eq([patched(:own)] * 2)
      expect(described_class.try_dispatch(site(integer, :ip, environment))).to eq(patched(:own))
    end

    # The scope's `self` decides a protected patch: `main` is no `Numeric`, and a `self` the site cannot name may be.
    it "refuses a protected patch from the top level, and answers it when the site has no scope" do
      expect(ask(:np, "1.np", scope: top_level)).to be_nil
      expect(described_class.try_dispatch(site(Rigor::Type::Combinator.nominal_of("Numeric"), :np, environment,
                                               call_node: call_node("1.np")))).to eq(patched(:numeric))
    end

    # The nearer patch is refused and a farther one would answer: neither refused nor typed from the nearer.
    it "answers Dynamic[top] when a farther patch of the name is one the call may reach" do
      shadowed = environment_with(patch("Integer", :sp, :own, visibility: :private), patch("Object", :sp, :object))
      scope = Rigor::Scope.empty(environment: shadowed)

      answer = described_class.try_dispatch(
        site(integer, :sp, shadowed, call_node: call_node("1.sp"), scope: scope), through_ancestors: true
      )
      expect(answer).to eq(untyped)
    end
  end

  # Issue #1708 — the second question `resolve_site` asks, below the tiers that answer the receiver's own class.
  describe ".try_dispatch through the ancestors" do
    def through(receiver, name, environment, scope = Rigor::Scope.empty(environment: environment))
      described_class.try_dispatch(site(receiver, name, environment, scope: scope), through_ancestors: true)
    end

    # A scope whose project source defines `methods` (`{ class name => { method name => side } }`) and writes the
    # `superclasses` (`{ class name => superclass name }`).
    def scope_defining(environment, methods, superclasses: {})
      empty = Rigor::Scope.empty(environment: environment)
      index = empty.discovery
      empty.with_discovery(
        index.with(discovered_methods: methods, possible_discovered_methods: index.possible_discovered_methods,
                   discovered_superclasses: superclasses)
      )
    end

    # A scope that holds only the `def` node of `Integer#name` (or of `Integer.name`), as it does for a plain `def` on
    # a class RBS declares: the class is known by another method, and the method table does not hold `name`.
    def scope_with_def_node(environment, name, table:, contested:)
      known = scope_defining(environment, { "Integer" => { other: :instance } })
      index = known.discovery
      node = Prism.parse("def #{name} = 1").value.statements.body.first
      known.with_discovery(index.with(table => { "Integer" => { name => node } },
                                      contested => index.public_send(contested)))
    end

    it "answers from a patch on an ancestor, for an instance and for the class object" do
      environment = environment_with(patch("Numeric", :nn, :numeric), patch("Object", :zz, :object))

      expect(through(integer, :nn, environment)).to eq(patched(:numeric))
      expect(through(integer, :zz, environment)).to eq(patched(:object))
      expect(through(integer_class, :zz, environment)).to eq(patched(:object))
    end

    it "declines a patch on a class that is not an ancestor" do
      expect(through(integer, :only_hash, environment_with(patch("Hash", :only_hash, :hash)))).to be_nil
    end

    # Ruby runs `class Integer; def nn` in the project's own source ahead of `class Object; def nn` in a patch file.
    it "stops at a nearer definition in the project's own source" do
      environment = environment_with(patch("Object", :nn, :object))
      reopened = scope_defining(environment, { "Integer" => { nn: :instance } })

      expect(through(integer, :nn, environment, reopened)).to be_nil
      expect(through(Rigor::Type::Combinator.nominal_of("Float"), :nn, environment, reopened)).to eq(patched(:object))
    end

    # `class Object; def nn` in the project's source is farther than the `Numeric` patch, so the patch answers: the
    # probe at `Integer` reads `Integer`'s own level of its chain and not the `Numeric` and `Object` levels the
    # project's `class Integer < Numeric` and `class Numeric < Object` put behind it.
    it "does not stop at a definition farther than the patch" do
      environment = environment_with(patch("Numeric", :nn, :numeric))
      farther = scope_defining(environment, { "Integer" => { other: :instance }, "Object" => { nn: :instance } },
                               superclasses: { "Integer" => "Numeric", "Numeric" => "Object" })

      expect(through(integer, :nn, environment, farther)).to eq(patched(:numeric))
    end

    it "builds no resolution chain for an ancestor the project's source does not open" do
      environment = environment_with(patch("Object", :zz, :object))
      allow(Rigor::Scope::ResolutionChain).to receive(:for).and_call_original

      expect(through(integer, :zz, environment)).to eq(patched(:object))
      expect(Rigor::Scope::ResolutionChain).not_to have_received(:for)
    end

    it "stops at a nearer definition the scope holds only as a `def` node, on either side" do
      environment = environment_with(patch("Object", :zz, :object))
      instance_def = scope_with_def_node(environment, :zz, table: :discovered_def_nodes,
                                                           contested: :contested_discovered_def_nodes)
      singleton_def = scope_with_def_node(environment, :zz, table: :discovered_singleton_def_nodes,
                                                            contested: :contested_discovered_singleton_def_nodes)

      expect(through(integer, :zz, environment, instance_def)).to be_nil
      expect(through(integer_class, :zz, environment, instance_def)).to eq(patched(:object))
      expect(through(integer_class, :zz, environment, singleton_def)).to be_nil
      expect(through(integer, :zz, environment, singleton_def)).to eq(patched(:object))
    end

    it "stops at a nearer singleton definition for a class object, and not at an instance one" do
      environment = environment_with(patch("Object", :zz, :object))
      singleton_def = scope_defining(environment, { "Integer" => { zz: :singleton } })

      expect(through(integer_class, :zz, environment, singleton_def)).to be_nil
      expect(through(integer, :zz, environment, singleton_def)).to eq(patched(:object))
    end
  end

  # Issue #1702 — an alias whose old name no patch binds names the method the class had before the patch. The tier
  # re-enters the dispatcher for it; `method_dispatcher_spec.rb` asks the real chain.
  describe "an alias of a method the patch files do not define" do
    let(:environment) { environment_with(patch("Integer", :old_plus, alias_of: :+)) }
    let(:block) { Rigor::Type::Combinator.nominal_of("Proc") }

    it "answers what MethodDispatcher.resolve answers for the old name, behind Dynamic, with this tier skipped" do
      allow(dispatcher).to receive(:resolve).and_return(integer)
      context = cc(receiver: integer, method_name: :old_plus, args: [integer], block_type: block,
                   environment: environment, call_node: call_node("1.old_plus(2)"))

      expect(described_class.try_dispatch(context)).to eq(Rigor::Type::Combinator.dynamic(integer))
      expect(dispatcher).to have_received(:resolve).with(
        receiver_type: integer, method_name: :+, arg_types: [integer], block_type: block,
        environment: environment, skip_project_patched: true
      )
    end

    it "answers Dynamic[top] when nothing answers the old name" do
      allow(dispatcher).to receive(:resolve).and_return(nil)

      expect(described_class.try_dispatch(site(integer, :old_plus, environment))).to eq(untyped)
    end

    it "does not re-enter the dispatcher for a patch that is not an alias" do
      allow(dispatcher).to receive(:resolve)

      expect(described_class.try_dispatch(site(integer, :bare, environment_with(patch("Integer", :bare)))))
        .to eq(untyped)
      expect(dispatcher).not_to have_received(:resolve)
    end
  end

  # The second entry: the user-class fallback asks it too, to keep private `Object` methods off an explicit receiver.
  describe ".explicit_non_self_receiver?" do
    it "is true for a call on a receiver other than `self`" do
      expect(described_class.explicit_non_self_receiver?(call_node("x.foo"))).to be(true)
      expect(described_class.explicit_non_self_receiver?(call_node("Foo.bar(1)"))).to be(true)
    end

    it "is false for a call on `self`, a call with no receiver, no node, and a node that has no receiver" do
      block_argument = call_node("foo(&:bar)").block

      expect(described_class.explicit_non_self_receiver?(call_node("self.foo"))).to be(false)
      expect(described_class.explicit_non_self_receiver?(call_node("foo"))).to be(false)
      expect(described_class.explicit_non_self_receiver?(nil)).to be(false)
      expect(described_class.explicit_non_self_receiver?(block_argument)).to be(false)
    end
  end
end
