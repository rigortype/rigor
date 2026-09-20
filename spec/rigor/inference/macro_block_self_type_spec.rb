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
      def sorbet_scope(env, supers:, extends:, known: %w[T::Sig], defines: { "T::Sig" => [:sig] })
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
        allow(scope).to receive(:discovered_method?) do |klass, meth, kind|
          kind == :instance && (defines[klass] || []).include?(meth)
        end
        scope
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
end
