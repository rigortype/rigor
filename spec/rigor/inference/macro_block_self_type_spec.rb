# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/macro_block_self_type"

RSpec.describe Rigor::Inference::MacroBlockSelfType do
  let(:plugin_class) do
    Class.new(Rigor::Plugin::Base) do
      manifest(
        id: "macroblockfixture",
        version: "0.1.0",
        block_as_methods: [
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Sinatra::Base",
            method_names: %i[get post]
          )
        ]
      )
    end
  end

  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
  end

  let(:registry) { Rigor::Plugin::Registry.new(plugins: [plugin_class.new(services: services)]) }
  let(:environment) { stub_environment(registry: registry, hierarchy: { "MyApp" => "Sinatra::Base" }) }

  let(:call_source) { "get '/foo' do; end" }
  let(:call_node) { Prism.parse(call_source).value.statements.body.first }

  def stub_environment(registry:, hierarchy:)
    env = instance_double(Rigor::Environment, plugin_registry: registry)
    allow(env).to receive(:nominal_for_name) { |name| Rigor::Type::Nominal.new(name) }
    allow(env).to receive(:class_ordering) do |lhs, rhs|
      if lhs == rhs
        :equal
      elsif hierarchy[lhs] == rhs
        :subclass
      else
        :unrelated
      end
    end
    allow(env).to receive(:singleton_extended_modules).and_return([])
    env
  end

  def scope_with(env)
    Rigor::Scope.empty(environment: env)
  end

  describe ".narrow_self_type_for" do
    it "narrows to Nominal[receiver] when Singleton[X] receiver inherits the constraint and the verb matches" do
      receiver_type = Rigor::Type::Singleton.new("MyApp")
      result = described_class.narrow_self_type_for(
        scope: scope_with(environment),
        call_node: call_node,
        receiver_type: receiver_type
      )
      expect(result).to eq(Rigor::Type::Nominal.new("MyApp"))
    end

    it "narrows to Nominal[X] when the receiver class equals the constraint" do
      receiver_type = Rigor::Type::Singleton.new("Sinatra::Base")
      result = described_class.narrow_self_type_for(
        scope: scope_with(environment),
        call_node: call_node,
        receiver_type: receiver_type
      )
      expect(result).to eq(Rigor::Type::Nominal.new("Sinatra::Base"))
    end

    it "returns nil when the verb is not in the entry's method_names list" do
      call = Prism.parse("delete '/foo' do; end").value.statements.body.first
      receiver_type = Rigor::Type::Singleton.new("MyApp")
      result = described_class.narrow_self_type_for(
        scope: scope_with(environment),
        call_node: call,
        receiver_type: receiver_type
      )
      expect(result).to be_nil
    end

    it "returns nil when the receiver class does not inherit the constraint" do
      env = stub_environment(registry: registry, hierarchy: { "Unrelated" => "Object" })
      result = described_class.narrow_self_type_for(
        scope: scope_with(env),
        call_node: call_node,
        receiver_type: Rigor::Type::Singleton.new("Unrelated")
      )
      expect(result).to be_nil
    end

    it "returns nil when the receiver is a Nominal (instance) rather than a Singleton (class)" do
      result = described_class.narrow_self_type_for(
        scope: scope_with(environment),
        call_node: call_node,
        receiver_type: Rigor::Type::Nominal.new("MyApp")
      )
      expect(result).to be_nil
    end

    describe "named self_type bindings (#1099)" do
      # Plain helper methods rather than `let` — the outer group's fixtures already
      # sit at the RSpec/MultipleMemoizedHelpers ceiling.
      def grape_plugin_class
        Class.new(Rigor::Plugin::Base) do
          manifest(
            id: "grapefixture",
            version: "0.1.0",
            block_as_methods: [
              Rigor::Plugin::Macro::BlockAsMethod.new(
                receiver_constraint: "Grape::API",
                method_names: %i[params],
                self_type: "Grape::Validations::ParamsScope"
              ),
              Rigor::Plugin::Macro::BlockAsMethod.new(
                receiver_constraint: "Grape::Validations::ParamsScope",
                method_names: %i[requires],
                self_type: "Grape::Validations::ParamsScope"
              ),
              Rigor::Plugin::Macro::BlockAsMethod.new(
                receiver_constraint: "Grape::API",
                method_names: %i[namespace],
                self_type: "singleton(Grape::API::Instance)"
              )
            ]
          )
        end
      end

      def grape_registry
        Rigor::Plugin::Registry.new(plugins: [grape_plugin_class.new(services: services)])
      end

      def grape_env
        env = stub_environment(registry: grape_registry, hierarchy: { "API" => "Grape::API" })
        allow(env).to receive(:singleton_for_name) { |name| Rigor::Type::Singleton.new(name) }
        env
      end

      it "narrows a Singleton receiver to a named instance class" do
        call = Prism.parse("params do; end").value.statements.body.first
        result = described_class.narrow_self_type_for(
          scope: scope_with(grape_env), call_node: call,
          receiver_type: Rigor::Type::Singleton.new("API")
        )
        expect(result).to eq(Rigor::Type::Nominal.new("Grape::Validations::ParamsScope"))
      end

      it "narrows a Singleton receiver to a named singleton class" do
        call = Prism.parse("namespace :x do; end").value.statements.body.first
        result = described_class.narrow_self_type_for(
          scope: scope_with(grape_env), call_node: call,
          receiver_type: Rigor::Type::Singleton.new("API")
        )
        expect(result).to eq(Rigor::Type::Singleton.new("Grape::API::Instance"))
      end

      it "matches a Nominal receiver for a named instance-binding entry" do
        call = Prism.parse("requires :x do; end").value.statements.body.first
        result = described_class.narrow_self_type_for(
          scope: scope_with(grape_env), call_node: call,
          receiver_type: Rigor::Type::Nominal.new("Grape::Validations::ParamsScope")
        )
        expect(result).to eq(Rigor::Type::Nominal.new("Grape::Validations::ParamsScope"))
      end

      it "does not match a Nominal receiver for a singleton-binding entry" do
        call = Prism.parse("namespace :x do; end").value.statements.body.first
        result = described_class.narrow_self_type_for(
          scope: scope_with(grape_env), call_node: call,
          receiver_type: Rigor::Type::Nominal.new("Grape::API::Instance")
        )
        expect(result).to be_nil
      end

      it "walks the scope's external-ancestor candidates when the environment cannot order the receiver" do
        env = instance_double(Rigor::Environment, plugin_registry: grape_registry)
        allow(env).to receive(:nominal_for_name) { |name| Rigor::Type::Nominal.new(name) }
        allow(env).to receive(:singleton_for_name) { |name| Rigor::Type::Singleton.new(name) }
        allow(env).to receive(:class_ordering) do |lhs, rhs|
          lhs == rhs ? :equal : :unknown
        end
        # `class API < ::Base` / `class Base < Grape::API` — the source-side superclass
        # table plus the nesting-aware candidate resolution the walk now goes through.
        scope = instance_double(
          Rigor::Scope,
          environment: env,
          discovered_superclasses: { "API" => "::Base", "Base" => "Grape::API" }
        )
        allow(scope).to receive(:ancestor_name_candidates) do |_subclass, raw|
          [raw.to_s.sub(/\A::/, "")]
        end
        call = Prism.parse("params do; end").value.statements.body.first
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: call,
          receiver_type: Rigor::Type::Singleton.new("API")
        )
        expect(result).to eq(Rigor::Type::Nominal.new("Grape::Validations::ParamsScope"))
      end
    end

    describe "extend-edge matching (#1097)" do
      # `class F; extend T::Sig; sig { ... }; end` — F does not INHERIT from `T::Sig`; the DSL
      # verb reaches the class object through the `extend` edge. The matcher therefore consults
      # `scope.discovered_extends` (source-side) and `Environment#singleton_extended_modules`
      # (RBS-side, e.g. `T::Struct`'s own `extend T::Sig`) alongside the inheritance walk.
      def sorbet_plugin_class
        Class.new(Rigor::Plugin::Base) do
          manifest(
            id: "sorbetfixture",
            version: "0.1.0",
            block_as_methods: [
              Rigor::Plugin::Macro::BlockAsMethod.new(
                receiver_constraint: "T::Sig",
                method_names: %i[sig],
                self_type: "T::Private::Methods::DeclBuilder"
              )
            ]
          )
        end
      end

      def sorbet_registry
        Rigor::Plugin::Registry.new(plugins: [sorbet_plugin_class.new(services: services)])
      end

      # `extends:` lists are in singleton-ancestor search order (nearest edge first), matching what
      # `record_extend_targets` stores. `known:` names the classes that exist in the fake universe —
      # an extend edge binds the first existing candidate — and `defines:` the instance methods each
      # module actually declares, which is what decides the call's owner.
      def sorbet_scope(env, supers:, extends:, known: %w[T::Sig],
                       defines: { "T::Sig" => [:sig] }, singleton_defines: {}, possible: {})
        scope = instance_double(
          Rigor::Scope,
          environment: env,
          discovered_superclasses: supers,
          discovered_extends: extends
        )
        allow(scope).to receive(:ancestor_name_candidates) do |_subclass, raw|
          [raw.to_s.sub(/\A::/, "")]
        end
        allow(scope).to receive(:known_user_class?) { |name| known.include?(name) }
        allow(scope).to receive(:singleton_def_shadows_call?) do |klass, meth, _node|
          (singleton_defines[klass] || []).include?(meth)
        end
        allow(scope).to receive(:instance_def_shadows_call?) do |klass, meth, _node|
          (defines[klass] || []).include?(meth)
        end
        allow(scope).to receive(:discovery).and_return(sorbet_discovery(possible))
        scope
      end

      # The possible-only side of DiscoveryIndex that the `extend` owner check reads (ADR-119 C1d-c).
      def sorbet_discovery(possible)
        discovery = instance_double(Rigor::Scope::DiscoveryIndex)
        allow(discovery).to receive(:possible_method?) do |klass, meth, _kind|
          (possible[klass] || []).include?(meth)
        end
        discovery
      end

      def sorbet_env(rbs_extends: {})
        env = instance_double(Rigor::Environment, plugin_registry: sorbet_registry)
        allow(env).to receive(:nominal_for_name) { |name| Rigor::Type::Nominal.new(name) }
        allow(env).to receive(:class_ordering) { |lhs, rhs| lhs == rhs ? :equal : :unknown }
        allow(env).to receive(:singleton_extended_modules) { |name| rbs_extends.fetch(name, []) }
        allow(env).to receive(:rbs_loader).and_return(nil)
        env
      end

      let(:sig_call) { Prism.parse("sig { returns(Integer) }").value.statements.body.first }

      it "matches a Singleton receiver whose class `extend`s the constraint module" do
        env = sorbet_env
        scope = sorbet_scope(env, supers: {}, extends: { "Fetcher" => ["T::Sig"] })
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: sig_call,
          receiver_type: Rigor::Type::Singleton.new("Fetcher")
        )
        expect(result).to eq(Rigor::Type::Nominal.new("T::Private::Methods::DeclBuilder"))
      end

      it "matches through an RBS-side `extend` edge on a discovered superclass" do
        # `class Doc < T::Struct` — Doc's own source has no `extend`, but T::Struct's bundled
        # RBS declares `extend T::Sig`, which `singleton_extended_modules` reports.
        env = sorbet_env(rbs_extends: { "T::Struct" => ["T::Sig", "T::Props::ClassMethods"] })
        scope = sorbet_scope(env, supers: { "Doc" => "T::Struct" }, extends: {})
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: sig_call,
          receiver_type: Rigor::Type::Singleton.new("Doc")
        )
        expect(result).to eq(Rigor::Type::Nominal.new("T::Private::Methods::DeclBuilder"))
      end

      it "does not match when the class extends an unrelated module" do
        env = sorbet_env
        scope = sorbet_scope(env, supers: {}, extends: { "Fetcher" => ["Other::DSL"] })
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: sig_call,
          receiver_type: Rigor::Type::Singleton.new("Fetcher")
        )
        expect(result).to be_nil
      end

      it "does not match when a nearer extended module owns the call" do
        # `extend T::Sig; extend CustomSig` — stored search order puts CustomSig first; it defines
        # `sig`, so its `sig` runs and picks the block self — not DeclBuilder.
        env = sorbet_env
        scope = sorbet_scope(
          env, supers: {}, extends: { "Fetcher" => ["CustomSig", "T::Sig"] },
               known: %w[T::Sig CustomSig], defines: { "CustomSig" => [:sig] }
        )
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: sig_call,
          receiver_type: Rigor::Type::Singleton.new("Fetcher")
        )
        expect(result).to be_nil
      end

      it "matches when a nearer extended module does not define the method" do
        env = sorbet_env
        scope = sorbet_scope(
          env, supers: {}, extends: { "Fetcher" => ["Plain", "T::Sig"] },
               known: %w[T::Sig Plain], defines: { "T::Sig" => [:sig] }
        )
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: sig_call,
          receiver_type: Rigor::Type::Singleton.new("Fetcher")
        )
        expect(result).to eq(Rigor::Type::Nominal.new("T::Private::Methods::DeclBuilder"))
      end

      it "does not match when the extended module's decisive `sig` def is only possible (ADR-119)" do
        env = sorbet_env
        scope = sorbet_scope(
          env, supers: {}, extends: { "Fetcher" => ["T::Sig"] }, possible: { "T::Sig" => [:sig] }
        )
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: sig_call,
          receiver_type: Rigor::Type::Singleton.new("Fetcher")
        )
        expect(result).to be_nil
      end

      it "still withholds when the class's own singleton `sig` def is possible (shadowing already withholds)" do
        env = sorbet_env
        scope = sorbet_scope(
          env, supers: {}, extends: { "Fetcher" => ["T::Sig"] },
               singleton_defines: { "Fetcher" => [:sig] }, possible: { "Fetcher" => [:sig] }
        )
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: sig_call,
          receiver_type: Rigor::Type::Singleton.new("Fetcher")
        )
        expect(result).to be_nil
      end

      it "does not match when the class defines its own singleton method" do
        # `def self.sig` on the class precedes every `extend` in the singleton ancestry — the
        # custom method answers and picks the block's self.
        env = sorbet_env
        scope = sorbet_scope(
          env, supers: {}, extends: { "Fetcher" => ["T::Sig"] },
               singleton_defines: { "Fetcher" => [:sig] }
        )
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: sig_call,
          receiver_type: Rigor::Type::Singleton.new("Fetcher")
        )
        expect(result).to be_nil
      end

      it "does not match a Nominal receiver through the extends edge" do
        env = sorbet_env
        scope = sorbet_scope(env, supers: {}, extends: { "Fetcher" => ["T::Sig"] })
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: sig_call,
          receiver_type: Rigor::Type::Nominal.new("Fetcher")
        )
        expect(result).to be_nil
      end
    end

    it "returns nil when the plugin registry is empty" do
      env = stub_environment(registry: Rigor::Plugin::Registry::EMPTY, hierarchy: { "MyApp" => "Sinatra::Base" })
      result = described_class.narrow_self_type_for(
        scope: scope_with(env),
        call_node: call_node,
        receiver_type: Rigor::Type::Singleton.new("MyApp")
      )
      expect(result).to be_nil
    end

    it "returns nil when the receiver_type is nil" do
      result = described_class.narrow_self_type_for(
        scope: scope_with(environment),
        call_node: call_node,
        receiver_type: nil
      )
      expect(result).to be_nil
    end

    it "returns nil gracefully when class_ordering raises (defensive)" do
      env = stub_environment(registry: registry, hierarchy: {})
      allow(env).to receive(:class_ordering).and_raise(StandardError, "boom")
      result = described_class.narrow_self_type_for(
        scope: scope_with(env),
        call_node: call_node,
        receiver_type: Rigor::Type::Singleton.new("MyApp")
      )
      expect(result).to be_nil
    end

    it "honours plugin registration order — the first matching entry wins" do
      reg = registry_with_two_get_plugins
      env = stub_environment(registry: reg, hierarchy: { "MyApp" => "Sinatra::Base" })
      expect(reg.plugins.first.manifest.id).to eq("first-tier-a")
      result = described_class.narrow_self_type_for(
        scope: scope_with(env),
        call_node: call_node,
        receiver_type: Rigor::Type::Singleton.new("MyApp")
      )
      expect(result).to eq(Rigor::Type::Nominal.new("MyApp"))
    end

    def make_get_plugin(id)
      Class.new(Rigor::Plugin::Base) do
        manifest(
          id: id,
          version: "0.1.0",
          block_as_methods: [
            Rigor::Plugin::Macro::BlockAsMethod.new(
              receiver_constraint: "Sinatra::Base",
              method_names: %i[get]
            )
          ]
        )
      end
    end

    def registry_with_two_get_plugins
      first = make_get_plugin("first-tier-a").new(services: services)
      second = make_get_plugin("second-tier-a").new(services: services)
      Rigor::Plugin::Registry.new(plugins: [first, second])
    end
  end

  # Issue #1667 — the entry's `refinements:` ride the match, and a `:lexical` entry keeps the caller's `self`.
  describe ".match_for" do
    def registry_for(entry)
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "macroblockrefined", version: "0.1.0", block_as_methods: [entry])
      end
      Rigor::Plugin::Registry.new(plugins: [klass.new(services: services)])
    end

    let(:build_node) { Prism.parse("build { }").value.statements.body.first }

    it "carries the entry's refinements beside the narrowed self" do
      entry = Rigor::Plugin::Macro::BlockAsMethod.new(
        receiver_constraint: "Object", method_names: %i[build], self_type: "Ctx", refinements: %w[SymSyntax]
      )
      env = stub_environment(registry: registry_for(entry), hierarchy: {})
      match = described_class.match_for(
        scope: scope_with(env), call_node: build_node, receiver_type: Rigor::Type::Nominal.new("Caller")
      )

      expected = described_class::Match.new(self_type: Rigor::Type::Nominal.new("Ctx"), refinements: %w[SymSyntax])
      expect(match).to eq(expected)
    end

    it "answers the calling scope's self for a :lexical entry, on a Nominal receiver" do
      entry = Rigor::Plugin::Macro::BlockAsMethod.new(
        receiver_constraint: "Object", method_names: %i[build], self_type: :lexical, refinements: %w[SymSyntax]
      )
      env = stub_environment(registry: registry_for(entry), hierarchy: {})
      scope = scope_with(env).with_self_type(Rigor::Type::Nominal.new("Caller"))
      match = described_class.match_for(
        scope: scope, call_node: build_node, receiver_type: Rigor::Type::Nominal.new("Caller")
      )

      expect(match.self_type).to eq(Rigor::Type::Nominal.new("Caller"))
      expect(described_class.apply(scope, match, keeps_unknown: false).declared_refinements).to eq(%w[SymSyntax])
    end
  end
end
