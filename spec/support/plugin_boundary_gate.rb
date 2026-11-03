# frozen_string_literal: true

require_relative "plugin_boundary"

# ADR-128 WD4 — switches the plugin-boundary recorder on for a whole rspec run and fails the run at its end when a
# bundled plugin reached past the plugin-facing interfaces. Loaded by `spec_helper.rb` only when
# `RIGOR_PLUGIN_BOUNDARY` is set (`make test-integration-plugins` and `bin/verify-changed` set it), because a
# `TracePoint` over every call roughly doubles a run's time. `spec_helper.rb` requires every `support/` file, so
# the guard below is what keeps the hooks off in an ordinary run.
#
# It records nothing from the default suite, whose plugin specs use fixture plugins outside `plugins/` and
# `examples/`; its coverage is whatever the plugin integration specs in the run exercise.
return unless ENV["RIGOR_PLUGIN_BOUNDARY"]

RSpec.configure do |config|
  recorder = PluginBoundary::Recorder.new

  config.before(:suite) { recorder.start }
  config.after(:suite) do
    recorder.stop
    PluginBoundary.check!(recorder)
  end
end
