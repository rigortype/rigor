# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/plugin/base"

# Issue #2689 fixture — a contribution in the shape of rigor-activerecord's gates: it types `Model.all` only while no
# project class on `Model`'s chain defines `default_scope`, asked through `Rigor::Reflection.project_method_defined` —
# by default `source: :discovered` (the discovery-table walk, `Scope#discovered_method_through_ancestors?`) on the
# singleton side; `.gate` switches the walk and the side. The gated name is not the called one on purpose: a call of
# the gated name itself also reads `visibility:*#<name>`, which any new def of the name fires, and would re-check the
# consumer without the walk's own edge. `incremental_state_fingerprint` keeps the plugin non-opaque (ADR-88 WD1), so its
# snapshot is reusable and a stale warm answer can show.
module Rigor
  module Plugin
    unless defined?(DiscoveredGateProbe)
      class DiscoveredGateProbe < Base
        manifest(id: "discovered-gate", version: "0.1.0")

        # The walk and the side the gate asks about; a spec example sets it before the session starts.
        DEFAULT_GATE = { source: :discovered, kind: :singleton }.freeze
        @gate = DEFAULT_GATE
        class << self
          attr_accessor :gate
        end

        dynamic_return methods: [:all] do |call_node, scope|
          next nil unless call_node.is_a?(Prism::CallNode)
          next nil if call_node.receiver.nil?

          gate = DiscoveredGateProbe.gate
          defined = Rigor::Reflection.project_method_defined(
            "Model", :default_scope, kind: gate[:kind], source: gate[:source], scope: scope
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
RSpec.describe "a plugin gate on the discovery walk across a warm recheck (#2689)" do
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
    Rigor::Analysis::IncrementalSession.new(configuration: config(dir), paths: [dir], plugin_requirer: requirer)
  end

  # The oracle: a cold (`--no-cache`) run of the edited tree under the same plugin.
  def cold_run(dir)
    Rigor::Plugin.unregister!
    runner = Rigor::Analysis::Runner.new(configuration: config(dir), cache_store: nil, plugin_requirer: requirer)
    guarded_run(runner).diagnostics
  end

  def sorted(diagnostics) = diagnostics.map { |d| [d.path, d.line, d.column, d.rule, d.message] }.sort

  def messages(diagnostics) = diagnostics.map(&:message)

  before do
    Rigor::Plugin.unregister!
    Rigor::Plugin::DiscoveredGateProbe.gate = Rigor::Plugin::DiscoveredGateProbe::DEFAULT_GATE
  end

  after do
    Rigor::Plugin.unregister!
    Rigor::Plugin::DiscoveredGateProbe.gate = Rigor::Plugin::DiscoveredGateProbe::DEFAULT_GATE
  end

  let(:gated) { "dump_type: PluginRecords" }

  # A guard: the consumer's own `Model` constant read already files `class:Model`, which the new declaring file fires,
  # so this held before #2689 too. It pins the scenario the issue names.
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

  # A guard: a hit reads the definer's file as a positive edge, so removal held before #2689 too.
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

  # The case #2689 broke: only the walk's miss on `Base` names it (`method:Base.default_scope` and `class:Base`, either
  # of which the new file fires).
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

  # The shapes #2689 review found: an ancestor the project declares with no methods, or does not declare at all yet,
  # is an EXTERNAL chain entry, which neither walk looked up. A new file that declares it with the method turns the
  # answer, and only the miss's `class:<name>` edge on that entry fires for it. Each shape runs under both walks.
  shapes = {
    "a: an abstract superclass with only a class-body call" => {
      kind: :singleton, consumer: "Model.all",
      files: { "application_record.rb" => "class ApplicationRecord\n  primary_abstract_class\nend\n",
               "model.rb" => "class Model < ApplicationRecord\nend\n" },
      added: { "application_record_scope.rb" => "class ApplicationRecord\n  def self.default_scope = nil\nend\n" }
    },
    "b: an empty superclass" => {
      kind: :singleton, consumer: "Model.all",
      files: { "application_record.rb" => "class ApplicationRecord\nend\n",
               "model.rb" => "class Model < ApplicationRecord\nend\n" },
      added: { "application_record_scope.rb" => "class ApplicationRecord\n  def self.default_scope = nil\nend\n" }
    },
    "c: an empty extended module" => {
      kind: :singleton, consumer: "Model.all",
      files: { "scoping.rb" => "module Scoping\nend\n", "model.rb" => "class Model\n  extend Scoping\nend\n" },
      added: { "scoping_scope.rb" => "module Scoping\n  def default_scope = nil\nend\n" }
    },
    "d: an empty included module" => {
      kind: :instance, consumer: "Model.new.all",
      files: { "scoping.rb" => "module Scoping\nend\n", "model.rb" => "class Model\n  include Scoping\nend\n" },
      # The discovery table does not carry a plain module instance `def` across files; an accessor it does.
      added: { "scoping_scope.rb" => "module Scoping\n  def default_scope = nil\nend\n" },
      added_discovered: { "scoping_scope.rb" => "module Scoping\n  attr_reader :default_scope\nend\n" }
    },
    "e: an empty superclass two levels up" => {
      kind: :singleton, consumer: "Model.all",
      files: { "root.rb" => "class Root\nend\n",
               "application_record.rb" => "class ApplicationRecord < Root\n  def self.where = 1\nend\n",
               "model.rb" => "class Model < ApplicationRecord\nend\n" },
      added: { "root_scope.rb" => "class Root\n  def self.default_scope = nil\nend\n" }
    },
    "f: an extended module no file declares yet" => {
      kind: :singleton, consumer: "Model.all",
      files: { "model.rb" => "class Model\n  extend Scoping\nend\n" },
      added: { "scoping.rb" => "module Scoping\n  def default_scope = nil\nend\n" }
    }
  }.freeze

  shapes.each do |label, shape|
    %i[discovered def].each do |source|
      it "re-checks the consumer when #{label} gains the method in a new file (source: #{source})" do
        Rigor::Plugin::DiscoveredGateProbe.gate = { source: source, kind: shape[:kind] }
        Dir.mktmpdir do |dir|
          shape[:files].each { |name, body| File.write(File.join(dir, name), body) }
          consumer = File.join(dir, "consumer.rb")
          File.write(consumer, "Rigor.dump_type(#{shape[:consumer]})\n")
          warm = session(dir)
          expect(messages(guarded_baseline(warm))).to include(gated)

          added = (source == :discovered && shape[:added_discovered]) || shape[:added]
          added.each { |name, body| File.write(File.join(dir, name), body) }
          recheck = guarded_recheck(warm)
          cold = cold_run(dir)

          expect(messages(cold)).not_to include(gated) # the edit turns the answer
          expect(recheck.affected).to include(consumer)
          expect(sorted(recheck.diagnostics)).to eq(sorted(cold))
        end
      end
    end
  end
end
