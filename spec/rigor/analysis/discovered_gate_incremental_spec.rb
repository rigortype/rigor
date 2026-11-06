# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/plugin/base"

# Issue #2689 fixture — a contribution in the shape of rigor-activerecord's gates: it types `Model.all` only while no
# project class on `Model`'s singleton chain defines `default_scope`, asked through
# `Rigor::Reflection.project_method_defined(source: :discovered)` (the discovery-table walk,
# `Scope#discovered_method_through_ancestors?`). The gated name is not the called one on purpose: a call of the gated
# name itself also reads `visibility:*#<name>`, which any new def of the name fires, and would re-check the consumer
# without the walk's own edge. `incremental_state_fingerprint` keeps the plugin non-opaque (ADR-88 WD1), so its
# snapshot is reusable and a stale warm answer can show.
module Rigor
  module Plugin
    unless defined?(DiscoveredGateProbe)
      class DiscoveredGateProbe < Base
        manifest(id: "discovered-gate", version: "0.1.0")

        dynamic_return methods: [:all] do |call_node, scope|
          next nil unless call_node.is_a?(Prism::CallNode)
          next nil unless call_node.receiver.is_a?(Prism::ConstantReadNode)
          next nil unless call_node.receiver.name == :Model

          defined = Rigor::Reflection.project_method_defined(
            "Model", :default_scope, kind: :singleton, source: :discovered, scope: scope
          )
          next nil unless defined.no?

          Rigor::Type::Combinator.nominal_of("PluginRecords")
        end

        def incremental_state_fingerprint
          "static-discovered-gate"
        end
      end
    end
  end
end

# The warm re-check of a consumer whose plugin answer turned on a discovery-walk MISS. Before #2689 the walk filed no
# negative `method:` / `class:` edge, so defining the method in a new file left the consumer served from cache.
RSpec.describe Rigor::Analysis::IncrementalSession, "discovery-walk gate (#2689)" do
  def requirer
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::DiscoveredGateProbe)
      true
    end
  end

  def config(dir)
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [dir], "plugins" => ["discovered-gate"]))
  end

  def session(dir)
    Rigor::Plugin.unregister!
    described_class.new(configuration: config(dir), paths: [dir], plugin_requirer: requirer)
  end

  # The oracle: a cold (`--no-cache`) run of the edited tree under the same plugin.
  def cold_run(dir)
    Rigor::Plugin.unregister!
    runner = Rigor::Analysis::Runner.new(configuration: config(dir), cache_store: nil, plugin_requirer: requirer)
    guarded_run(runner).diagnostics
  end

  def sorted(diagnostics) = diagnostics.map { |d| [d.path, d.line, d.column, d.rule, d.message] }.sort

  def messages(diagnostics) = diagnostics.map(&:message)

  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:gated) { "dump_type: PluginRecords" }

  it "re-checks the consumer when a new file reopens the class with the method" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), "class Model\nend\n")
      consumer = File.join(dir, "consumer.rb")
      File.write(consumer, "Rigor.dump_type(Model.all)\n")
      warm = session(dir)
      expect(messages(guarded_baseline(warm))).to include(gated)

      File.write(File.join(dir, "model_scope.rb"), "class Model\n  def self.default_scope = nil\nend\n")
      recheck = guarded_recheck(warm)

      expect(recheck.affected).to include(consumer)
      expect(messages(recheck.diagnostics)).not_to include(gated)
      expect(sorted(recheck.diagnostics)).to eq(sorted(cold_run(dir)))
    end
  end

  it "re-checks the consumer when the method is removed again" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "model.rb"), "class Model\nend\n")
      scoped = File.join(dir, "model_scope.rb")
      File.write(scoped, "class Model\n  def self.default_scope = nil\nend\n")
      consumer = File.join(dir, "consumer.rb")
      File.write(consumer, "Rigor.dump_type(Model.all)\n")
      warm = session(dir)
      expect(messages(guarded_baseline(warm))).not_to include(gated)

      File.write(scoped, "class Model\nend\n")
      recheck = guarded_recheck(warm)

      expect(messages(recheck.diagnostics)).to include(gated)
      expect(sorted(recheck.diagnostics)).to eq(sorted(cold_run(dir)))
    end
  end

  it "re-checks the consumer when a superclass in another file gains the method" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.rb"), "class Base\n  def self.where = 1\nend\n")
      File.write(File.join(dir, "model.rb"), "class Model < Base\nend\n")
      consumer = File.join(dir, "consumer.rb")
      File.write(consumer, "Rigor.dump_type(Model.all)\n")
      warm = session(dir)
      expect(messages(guarded_baseline(warm))).to include(gated)

      File.write(File.join(dir, "base_scope.rb"), "class Base\n  def self.default_scope = nil\nend\n")
      recheck = guarded_recheck(warm)

      expect(recheck.affected).to include(consumer)
      expect(messages(recheck.diagnostics)).not_to include(gated)
      expect(sorted(recheck.diagnostics)).to eq(sorted(cold_run(dir)))
    end
  end
end
