# frozen_string_literal: true

require "spec_helper"

require "rigor/analysis/crash_signature"
require "rigor/analysis/diagnostic"
require "rigor/analysis/result"

# Issues #665 / #674 / #683 / #686 / #696 — the one definition of "an internal failure made this run report
# less than it should have". Four consumers used to recognise these shapes by matching the diagnostic MESSAGE
# with their own string literal; this pins the shared table so a fifth copy is never the cheap option, and so
# a reworded message goes red HERE rather than silently disarming a guard.
#
# Every example below asserts a POSITIVE classification or a positive non-classification against a real
# diagnostic shape. An "it returns nil for everything" spec would pass on a predicate that answered nil
# unconditionally — which is exactly the disarmed state this module exists to prevent.
RSpec.describe Rigor::Analysis::CrashSignature do
  def diagnostic(message: "boom", severity: :error, rule: nil, source_family: :builtin)
    Rigor::Analysis::Diagnostic.new(
      path: "app.rb", line: 1, column: 1, message: message,
      severity: severity, rule: rule, source_family: source_family
    )
  end

  # The exact row `Runner#analyze_file_body` / `WorkerSession#analyze_body` build in their `rescue
  # StandardError`, message prefix included.
  def check_rule_crash
    diagnostic(message: "internal analyzer error: RuntimeError: boom")
  end

  # The exact row `Runner#collect_plugin_diagnostics` builds when a plugin raises out of its envelope.
  def plugin_crash
    diagnostic(message: "plugin `demo` raised", rule: "runtime-error", source_family: :plugin_loader)
  end

  describe ".reason" do
    it "classifies the check-rule rescue by its message prefix" do
      expect(described_class.reason(check_rule_crash)).to eq(:check_rule)
    end

    it "classifies the plugin-isolation row by its (severity, source_family, rule) triple" do
      expect(described_class.reason(plugin_crash)).to eq(:plugin)
    end

    it "classifies both RBS build-failure rules" do
      reasons = described_class::RBS_BUILD_FAILURE_RULES.map do |rule|
        described_class.reason(diagnostic(message: "…", severity: :warning, rule: rule))
      end

      expect(reasons).to eq(%i[rbs_build rbs_build])
    end

    it "leaves an ordinary rule diagnostic unclassified" do
      ordinary = diagnostic(message: "undefined method `x'", rule: "call.undefined-method")

      expect(described_class.reason(ordinary)).to be_nil
    end

    # The plugin shape is keyed on the triple, not on the bare rule name: a plugin may define its own
    # `"runtime-error"` under its OWN `source_family`, and several guarded specs assert on a plugin-authored
    # `"load-error"` legitimately. Matching the name alone would make those firings look like crashes.
    it "does not claim a plugin's own rule under its own source family" do
      own = diagnostic(message: "demo failed", rule: "runtime-error", source_family: "plugin.demo")

      expect(described_class.reason(own)).to be_nil
    end
  end

  describe ".analyzer_failed?" do
    it "is true for the two rescue-produced shapes, where nothing ran" do
      expect([check_rule_crash, plugin_crash].map { |d| described_class.analyzer_failed?(d) }).to eq([true, true])
    end

    # The adjudication the module records: an RBS build failure is a DEGRADATION the analysis reports about
    # itself, not an escaped exception. Every rule still fired; the type universe was smaller. Treating it as
    # a crash would fail every consumer that guards against a bug, on a state a project legitimately sits on
    # while it fixes its `sig/`.
    it "is false for an RBS build failure, which the run completed and reported" do
      failures = described_class::RBS_BUILD_FAILURE_RULES.map do |rule|
        described_class.analyzer_failed?(diagnostic(message: "…", severity: :warning, rule: rule))
      end

      expect(failures).to eq([false, false])
    end
  end

  describe ".describe" do
    it "names the shape and the position, so a raise says which crash it saw and where" do
      expect(described_class.describe(check_rule_crash))
        .to eq("check_rule at app.rb:1: internal analyzer error: RuntimeError: boom")
    end
  end

  describe Rigor::Analysis::Result do
    it "answers crashed? and names the culprit when a check rule raised" do
      result = described_class.new(diagnostics: [diagnostic(message: "ok", rule: "call.undefined-method"),
                                                 check_rule_crash])

      expect(result.crashed?).to be(true)
      expect(result.crash_diagnostics.map(&:message)).to eq(["internal analyzer error: RuntimeError: boom"])
    end

    # The must-still-succeed half: a result carrying real findings is not a crash, so a consumer that refuses
    # crashed runs still measures every healthy one.
    it "answers false for a result carrying only real diagnostics" do
      result = described_class.new(diagnostics: [diagnostic(message: "undefined", rule: "call.undefined-method")])

      expect(result.crashed?).to be(false)
      expect(result.crash_diagnostics).to be_empty
    end
  end
end
