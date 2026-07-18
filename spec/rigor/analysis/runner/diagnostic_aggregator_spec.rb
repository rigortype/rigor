# frozen_string_literal: true

require "spec_helper"

# #194 slice 1 — the `plugin_loader.load-error` diagnostic names the file a plugin loaded from when the
# require SUCCEEDED but a later step (config / instantiation) failed, so an engine↔plugin version skew is a
# one-line diagnosis; a require that failed outright keeps its original message. That message composition
# lives in the aggregator, so it is exercised here directly against a hand-built registry — no real load
# path, no `$LOADED_FEATURES`.
RSpec.describe Rigor::Analysis::Runner::DiagnosticAggregator do
  # `plugin_load_diagnostics` reads only the plugin registry, so every other collaborator is an inert stub.
  def build_aggregator(registry)
    described_class.new(
      configuration: Rigor::Configuration.new(Rigor::Configuration::DEFAULTS),
      rbs_extended_reporter: nil,
      boundary_cross_reporter: nil,
      source_rbs_synthesis_reporter: nil,
      plugin_registry: -> { registry },
      dependency_source_index: -> {},
      pool_mode: -> { false },
      cached_plugin_prepare_diagnostics: -> { [] },
      pre_eval_diagnostics_from_scanner: -> { [] },
      synthesized_namespaces_snapshot: -> {},
      quarantined_signatures_snapshot: -> { [] },
      env_build_failure_snapshot: -> {},
      conformance_results_snapshot: -> {}
    )
  end

  def load_error(message, resolved_path: nil)
    error = Rigor::Plugin::LoadError.new(message, plugin_ref: "x")
    error.resolved_path = resolved_path
    error
  end

  it "appends the resolved file to a post-require failure so it names the loaded plugin copy" do
    registry = Rigor::Plugin::Registry.new(
      load_errors: [
        load_error('plugin "x" raised during init: RuntimeError: boom',
                   resolved_path: "/checkout/plugins/rigor-x/lib/rigor-x.rb")
      ]
    )

    diagnostic = build_aggregator(registry).plugin_load_diagnostics.first

    expect(diagnostic.rule).to eq("load-error")
    expect(diagnostic.source_family).to eq(:plugin_loader)
    expect(diagnostic.message).to eq(
      'plugin "x" raised during init: RuntimeError: boom ' \
      "(loaded from /checkout/plugins/rigor-x/lib/rigor-x.rb)"
    )
  end

  it "leaves a require-failure message unchanged when no file was resolved" do
    registry = Rigor::Plugin::Registry.new(
      load_errors: [load_error('could not load plugin gem "rigor-y": cannot load such file')]
    )

    diagnostic = build_aggregator(registry).plugin_load_diagnostics.first

    expect(diagnostic.message).to eq('could not load plugin gem "rigor-y": cannot load such file')
    expect(diagnostic.message).not_to include("loaded from")
  end
end
