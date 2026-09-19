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
        # `class API < ::Base` / `class Base < Grape::API` — the resolved candidate groups
        # `external_ancestor_name_candidates` returns for a two-hop source-side ancestry.
        scope = instance_double(
          Rigor::Scope,
          environment: env,
          external_ancestor_name_candidates: [["Base"], ["Grape::API"]]
        )
        call = Prism.parse("params do; end").value.statements.body.first
        result = described_class.narrow_self_type_for(
          scope: scope, call_node: call,
          receiver_type: Rigor::Type::Singleton.new("API")
        )
        expect(result).to eq(Rigor::Type::Nominal.new("Grape::Validations::ParamsScope"))
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
