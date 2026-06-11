# frozen_string_literal: true

# Catch drift between docs/manual/ prose and the implementation it
# describes.  Three axes:
#
#   1. CLI subcommands — every key in CLI::HANDLERS must appear in
#      the CLI reference, and vice versa.
#   2. Config keys — every top-level key in Configuration::DEFAULTS
#      must be mentioned in the configuration reference.
#   3. Rule IDs — every ID in CheckRules::ALL_RULES must appear in
#      the diagnostic catalogue or the handbook errors chapter.
#
# These checks are purely textual — no Rigor analysis needed.

require "spec_helper"

require "rigor/cli"
require "rigor/configuration"
require "rigor/analysis/check_rules"

# Constants at file scope so nested describe/let blocks can resolve them.
MANUAL_DRIFT_DOCS_ROOT    = File.expand_path("../../docs", __dir__)
MANUAL_DRIFT_MANUAL_DIR   = File.join(MANUAL_DRIFT_DOCS_ROOT, "manual")
MANUAL_DRIFT_HANDBOOK_DIR = File.join(MANUAL_DRIFT_DOCS_ROOT, "handbook")

# Introspection helpers: emitted by the engine but documented in the
# handbook type-inspection chapter (05), not the diagnostic catalogue.
MANUAL_DRIFT_INTROSPECTION_RULES = %w[dump.type assert.type-mismatch].freeze

RSpec.describe "manual accuracy" do
  # ── 1. CLI subcommand coverage ──────────────────────────────────

  describe "CLI subcommands (02-cli-reference.md)" do
    let(:handler_keys) { Rigor::CLI::HANDLERS.keys }
    let(:cli_doc) { File.read(File.join(MANUAL_DRIFT_MANUAL_DIR, "02-cli-reference.md"), encoding: "utf-8") }

    it "every HANDLERS subcommand is mentioned in the reference" do
      undocumented = handler_keys.reject do |cmd|
        cli_doc.include?("`rigor #{cmd}`") || cli_doc.include?("`#{cmd}`")
      end
      expect(undocumented).to be_empty,
                              "CLI::HANDLERS keys not mentioned in 02-cli-reference.md: " \
                              "#{undocumented.inspect}\nAdd a section for each missing subcommand."
    end
  end

  # ── 2. Config key coverage ───────────────────────────────────────

  describe "configuration keys (03-configuration.md)" do
    let(:top_level_keys) { Rigor::Configuration::DEFAULTS.keys }
    let(:config_doc) { File.read(File.join(MANUAL_DRIFT_MANUAL_DIR, "03-configuration.md"), encoding: "utf-8") }

    it "every DEFAULTS top-level key is mentioned in the reference" do
      missing = top_level_keys.reject do |key|
        # Accept backtick forms, YAML-key form (key:), or dot-notation
        # prefix (cache.path, bundler.lockfile, …).
        config_doc.include?("`#{key}`") ||
          config_doc.include?("`#{key}:`") ||
          config_doc.include?("#{key}:") ||
          config_doc.include?("#{key}.")
      end
      expect(missing).to be_empty,
                         "Configuration::DEFAULTS keys not mentioned in 03-configuration.md: " \
                         "#{missing.inspect}\nAdd documentation for each missing key."
    end
  end

  # ── 3. Rule ID coverage ──────────────────────────────────────────

  describe "diagnostic rule IDs (04-diagnostics.md + handbook/08)" do
    let(:all_rules) { Rigor::Analysis::CheckRules::ALL_RULES }
    let(:combined_doc) do
      File.read(File.join(MANUAL_DRIFT_MANUAL_DIR, "04-diagnostics.md"), encoding: "utf-8") +
        File.read(File.join(MANUAL_DRIFT_HANDBOOK_DIR, "08-understanding-errors.md"), encoding: "utf-8")
    end

    it "every CheckRules::ALL_RULES entry appears in the diagnostic docs" do
      missing = (all_rules - MANUAL_DRIFT_INTROSPECTION_RULES).reject { |r| combined_doc.include?(r) }
      expect(missing).to be_empty,
                         "Rule IDs in ALL_RULES not mentioned in diagnostic docs: #{missing.inspect}\n" \
                         "Add each rule to manual/04-diagnostics.md or handbook/08-understanding-errors.md."
    end
  end
end
