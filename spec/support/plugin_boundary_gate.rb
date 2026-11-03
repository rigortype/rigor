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
#
# `RIGOR_PLUGIN_BOUNDARY_REQUIRE_CALLS=1` (set by `make test-integration-plugins`) also fails a run that recorded no
# plugin->engine call. Every run that executes a plugin integration example checks that a plugin file was loaded and
# that the recorder went live, whatever the variable says.
return unless ENV["RIGOR_PLUGIN_BOUNDARY"]

RSpec.configure do |config|
  recorder = PluginBoundary::Recorder.new
  require_calls = ENV["RIGOR_PLUGIN_BOUNDARY_REQUIRE_CALLS"] == "1"

  config.before(:suite) { recorder.start }
  # `rerun_file_path` names the spec file that ran the example; `file_path` names the file that defined a shared group.
  config.after { |example| recorder.note_example(example.metadata[:rerun_file_path]) }
  config.after(:suite) do
    recorder.stop
    config.reporter.message("plugin-boundary gate: #{recorder.calls.size} distinct plugin->engine call(s) recorded")
    PluginBoundary.check!(recorder, require_calls: require_calls)
  end
end
