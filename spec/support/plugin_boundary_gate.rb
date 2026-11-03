# frozen_string_literal: true

require_relative "plugin_boundary"

# ADR-128 WD4 — switches the plugin-boundary recorder on for a whole rspec run and fails the run at its end when a
# bundled plugin reached past the plugin-facing interfaces. Loaded by `spec_helper.rb` only when
# `RIGOR_PLUGIN_BOUNDARY` is set, because a `TracePoint` over every call roughly doubles a run's time.
# `make test-integration-plugins` sets it; `bin/verify-changed` does not, so CI is the gate. `spec_helper.rb`
# requires every `support/` file, so the guard below is what keeps the hooks off in an ordinary run.
#
# It records nothing from the default suite, whose plugin specs use fixture plugins outside `plugins/` and
# `examples/`; its coverage is whatever the plugin integration specs in the run exercise.
return unless ENV["RIGOR_PLUGIN_BOUNDARY"]

RSpec.configure do |config|
  recorder = PluginBoundary::Recorder.new
  integration_ran = false

  config.before(:suite) { recorder.start }
  config.after do |example|
    integration_ran ||= PluginBoundary.integration_spec?(example.metadata[:file_path])
  end
  config.after(:suite) do
    recorder.stop
    config.reporter.message("plugin-boundary gate: #{recorder.calls.size} distinct plugin->engine call(s) recorded")
    PluginBoundary.check!(recorder, require_root_file: true, integration_ran: integration_ran)
  end
end
