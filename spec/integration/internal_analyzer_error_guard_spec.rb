# frozen_string_literal: true

# Issue #665 — pins that {InternalAnalyzerErrorGuard} actually fires through the REAL analyzer rescue sites
# (`Runner#analyze_file_body`'s `rescue StandardError` at `lib/rigor/analysis/runner.rb:1736-1746`), not just
# against a hand-built `Diagnostic`. Every other spec that exercises `RunnerHelpers#analyze` /
# `PluginHelpers#run_plugin` asserts on the engine's own output, so none of them would notice if a future
# rewording of the rescue's message disarmed the guard's prefix match — the reviewer demonstrated exactly
# that on this branch: rewording `runner.rb:1742` alone reproduced master's vacuity (railties 16/13) while
# every other spec in the suite stayed green. This file is the one spec whose whole point is that wording.
require "spec_helper"

RSpec.describe "InternalAnalyzerErrorGuard fires through the real analyzer rescue" do
  include RunnerHelpers
  include Rigor::IntegrationSupport::PluginHelpers

  # A minimal in-spec plugin (same pattern as `macro_block_self_type_integration_spec.rb`'s `tier_a_plugin`)
  # — it emits no diagnostics of its own, so `run_plugin`'s Result reflects only the check-rule pipeline.
  let(:plugin_class) do
    klass = Class.new(Rigor::Plugin::Base) do
      manifest(id: "guardtest665", version: "0.1.0")
    end
    stub_const("FakePluginGuardTest665", klass)
    klass
  end

  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  it "returns a Result normally on a clean run (control)" do
    expect(analyze("x = 1\n")).to be_a(Rigor::Analysis::Result)
    expect(run_plugin(source: "x = 1\n")).to be_a(Rigor::Analysis::Result)
  end

  context "when a check rule raises inside CheckRules.diagnose" do
    before do
      allow(Rigor::Analysis::CheckRules).to receive(:diagnose).and_raise(NameError, "reviewer-injected boom")
    end

    it "raises AnalyzerCrashed through RunnerHelpers#analyze" do
      expect { analyze("x = 1\n") }.to raise_error(
        InternalAnalyzerErrorGuard::AnalyzerCrashed, /internal analyzer error/
      )
    end

    it "raises AnalyzerCrashed through PluginHelpers#run_plugin" do
      expect { run_plugin(source: "x = 1\n") }.to raise_error(
        InternalAnalyzerErrorGuard::AnalyzerCrashed, /internal analyzer error/
      )
    end
  end

  context "when a PLUGIN raises inside #diagnostics_for_file" do
    # ADR-52 WD1 — only a plugin that overrides `#diagnostics_for_file` (or declares a `node_rule`) is
    # visited at all, so this plugin must actually override the hook to reach `Runner#collect_plugin_diagnostics`'s
    # rescue (`runner.rb` ~L1447-1481) — the SECOND crash site {InternalAnalyzerErrorGuard} covers, distinct
    # from `CheckRules.diagnose` above. Its diagnostic never starts with "internal analyzer error", so this
    # pins the `(severity, source_family, rule)` match in {InternalAnalyzerErrorGuard.crash?} instead.
    let(:plugin_class) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(id: "guardtest665crash", version: "0.1.0")

        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          raise NameError, "reviewer-injected plugin boom"
        end
      end
      stub_const("FakePluginGuardTest665Crash", klass)
      klass
    end

    it "raises AnalyzerCrashed through PluginHelpers#run_plugin" do
      expect { run_plugin(source: "x = 1\n") }.to raise_error(
        InternalAnalyzerErrorGuard::AnalyzerCrashed, /raised during diagnostics_for_file/
      )
    end
  end
end
