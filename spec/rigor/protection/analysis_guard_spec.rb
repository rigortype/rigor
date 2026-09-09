# frozen_string_literal: true

require "spec_helper"

require "rigor/analysis/diagnostic"
require "rigor/analysis/result"
require "rigor/protection/analysis_guard"

# Issue #686 — the seam both ADR-69 kill oracles route every analysis through. A kill is decided by SET
# DIFFERENCE between a baseline run's diagnostics and a mutant's, so a run whose diagnostics say nothing
# about the code must be refused rather than compared: a crashed check rule leaves the identical synthetic
# row on both sides, the difference is empty, and the mutant is scored a SURVIVOR instead of indeterminate.
#
# What this file pins is the LINE between "refuse" and "still measure", because getting it wrong in either
# direction inflates the harness's headline signal. The review of the first cut armed too much: refusing the
# plugin-isolation row took a real `killed=1 survived=6` measurement to `killed=0 survived=0`, and since a
# raising `#prepare` appends its row to every sequential run, it would have refused every run for the life
# of the process.
RSpec.describe Rigor::Protection::AnalysisGuard do
  def diagnostic(message:, severity: :error, rule: nil, source_family: :builtin)
    Rigor::Analysis::Diagnostic.new(
      path: "app.rb", line: 1, column: 1, message: message,
      severity: severity, rule: rule, source_family: source_family
    )
  end

  def real_finding
    diagnostic(message: "undefined method `x'", rule: "call.undefined-method")
  end

  def result(*diagnostics)
    Rigor::Analysis::Result.new(diagnostics: diagnostics)
  end

  it "hands back the diagnostics of a healthy run" do
    healthy = result(real_finding)

    expect(described_class.checked(healthy, context: "spec")).to equal(healthy.diagnostics)
  end

  # The check-rule rescue wraps the whole per-file body, so `[crash_row]` is all that comes back — the real
  # findings are gone, and comparing two of these reports agreement about nothing.
  it "refuses a run whose file analysis was replaced by a crash row" do
    crashed = result(diagnostic(message: "internal analyzer error: RuntimeError: boom"))

    expect { described_class.checked(crashed, context: "DiagnosticOracle re-analysis of a.rb") }
      .to raise_error(Rigor::Protection::AnalyzerCrashed, /internal analyzer error/)
  end

  it "names the seam and the shape it saw, so the raise points somewhere" do
    crashed = result(diagnostic(message: "internal analyzer error: RuntimeError: boom"))

    expect { described_class.checked(crashed, context: "ClosureKillOracle closure analysis of a.rb") }
      .to raise_error(Rigor::Protection::AnalyzerCrashed, /ClosureKillOracle closure analysis of a\.rb.*check_rule/m)
  end

  # Issue #686 review, F2 — the measurement-preserving half, and the reason this is not simply "refuse
  # anything that looks like a failure". `collect_plugin_diagnostics` replaces only the raising plugin's
  # contribution; `CheckRules.diagnose` has already returned, so the run still carries every builtin rule's
  # findings and is still a measurement.
  it "still measures a run carrying the plugin-isolation row, findings and all" do
    plugin_row = diagnostic(message: "plugin `demo` raised", rule: "runtime-error", source_family: :plugin_loader)
    finding = real_finding
    measured = result(finding, plugin_row)

    expect(described_class.checked(measured, context: "spec")).to eq([finding, plugin_row])
  end

  # The same reasoning one tier further out: an RBS build failure the USER caused means every rule ran over
  # a smaller type universe, which is a degradation the run reports about itself, not an absence of
  # analysis. The site filter that admits mutations already drops receivers whose type did not resolve, so a
  # class whose definition failed contributes no measured sites to begin with.
  #
  # The set is `RBS_BUILD_FAILURE_RULES` minus the analyzer-defect rungs, and the subtraction is written out
  # rather than listing the two rule ids: a fourth rung added on either side of that line then joins the
  # example it belongs to instead of quietly widening this one.
  it "still measures a run carrying a user-caused RBS build-failure warning" do
    user_caused = Rigor::Analysis::CrashSignature::RBS_BUILD_FAILURE_RULES -
                  Rigor::Analysis::CrashSignature::ANALYZER_DEFECT_RULES

    expect(user_caused).not_to be_empty # non-vacuity: an empty list would pass this for free
    user_caused.each do |rule|
      degraded = result(real_finding, diagnostic(message: "…", severity: :warning, rule: rule))

      expect(described_class.checked(degraded, context: "spec").size).to eq(2)
    end
  end

  # Issue #790 — the rung on the other side of that line. The run is readable, so `Result#crashed?` is
  # false and the example above's reasoning would let it through; but the universe it measured is missing
  # the type constructors Rigor itself failed to build, the baseline carries the identical row, and the set
  # difference is empty for a reason that has nothing to do with the mutant.
  it "refuses a run carrying a row whose cause is Rigor rather than the project's signatures" do
    Rigor::Analysis::CrashSignature::ANALYZER_DEFECT_RULES.each do |rule|
      degraded = result(real_finding, diagnostic(message: "the HKT scan raised", rule: rule))

      expect { described_class.checked(degraded, context: "spec") }
        .to raise_error(Rigor::Protection::AnalyzerCrashed) { |e| expect(e).to be_analyzer_defect }
    end
  end

  # The refusals are told apart by the exception, not by its wording: the caller that owns the Environment
  # has to rebuild after a defect and must not rebuild after a crashed check rule, which left the
  # Environment as it found it.
  it "marks only the defect refusal as one whose cause outlives the run" do
    crashed = result(diagnostic(message: "internal analyzer error: RuntimeError: boom"))

    expect { described_class.checked(crashed, context: "spec") }
      .to raise_error(Rigor::Protection::AnalyzerCrashed) { |e| expect(e).not_to be_analyzer_defect }
  end

  # Issue #790 — the row is severity-stamped like every other diagnostic, so `severity_overrides:`
  # resolving it to `off` deletes it from the result and the harness that exists to find analyzer defects
  # sees a clean run. The Environment records the failure BEFORE severity resolution, so the guard asks it
  # too. `respond_to?` rather than a nil check: the oracles' collaborator here is a real Environment, and a
  # caller with none (or a double) must lose only this half.
  it "refuses on the Environment's pre-severity record when the row itself was stamped off" do
    environment = double(hkt_scan_failure: ["RuntimeError", "boom", "lib/rigor/environment.rb:1", :scan])
    stamped_off = result(real_finding)

    expect { described_class.checked(stamped_off, context: "spec", environment: environment) }
      .to raise_error(Rigor::Protection::AnalyzerCrashed, /scan HKT registry build raised RuntimeError: boom/)
  end

  it "measures a run over an Environment that recorded no shared-build failure" do
    environment = double(hkt_scan_failure: nil)
    healthy = result(real_finding)

    expect(described_class.checked(healthy, context: "spec", environment: environment).size).to eq(1)
  end
end
