# frozen_string_literal: true

# ADR-107 gate G3 (issue #825) — every declaration in `sig/` earns its place in one of three ways.
#
# ADR-107 § Decision gives `sig/` a provenance rule that follows ADR-5's asymmetry: a RETURN type is
# generated (clause 1 — `rigor sig-gen` proves it from the body), a PARAMETER type is authored intent
# (clause 2 keeps it lenient and inference never derives one), and anything else hand-written is a gap
# `sig-gen` could not close, which ADR-14's contradiction rule says must be RECORDED rather than
# assumed. `spec/support/sig_provenance_auditor.rb` carries the classifier and the marker convention:
#
#     # sig-gen gap: #825 — `void` is not a wide return to narrow.
#     def register: (Module class_object) -> void
#
# == Two mechanisms, and why not one
#
# The seeding audit (`docs/notes/20260908-sig-provenance-audit.md`) found 358 of 1,052 in-scope
# declarations earned and 679 residue — 671 once the nine stale declarations the audit also turned up
# were deleted. A per-declaration marker on 671 rows is not a gate, it is a rewrite of `sig/`, and a
# check that fires 671 times on a correct tree is the false-positive failure mode AGENTS.md
# § Implementation Guidelines puts above worst-case static reading. So:
#
# 1. HARD RULE on `tighter_return`. `sig-gen` proposes a narrower return than the declaration; ADR-14
#    says apply it or record why not, and there are 15, so a marker on each is affordable. A
#    sixteenth fails on arrival.
# 2. RATCHET on the residue. Per-file unmarked-residue counts are an exact snapshot below. A new
#    hand-written declaration raises its file's count and goes red; marking it subtracts from the
#    count. Closing an engine gap lowers a count and the gate says so, so slack cannot accumulate.
#
# == Why this file and not `spec/docs/`
#
# The classifier runs `SigGen::Generator` over all of `lib/` in-process — ~10 s on a 12-core M3 Max,
# paid once at file load (measured 2026-09-08: this file loads in 10.4 s and its examples run in
# 2.6 s). `make docs-check` is 1.2 s of load plus 5.4 s of examples today, so hanging this off it
# would nearly triple the cheap gate. It belongs with the other `sig-gen` specs, where CI's sharded
# `Tests` job already carries the cost.
require "spec_helper"
require "fileutils"
require "tmpdir"

SIG_PROVENANCE_ROOT = File.expand_path("../../..", __dir__)

# Computed once (a ~14 s generator pass) and shared read-only across the corpus examples.
SIG_PROVENANCE_ROWS = SigProvenanceAuditor.audit(root: SIG_PROVENANCE_ROOT)

# A corpus failure must stay readable; the total is always stated even when the listing is truncated.
SIG_PROVENANCE_LISTING_CAP = 200

# Unmarked residue per file, exact. Raise a number only with the reason in the commit body; lower one
# whenever an engine fix or a marker earns it. Files absent from the map must carry zero residue.
# Seeded 2026-09-08 from the audit note's table; total 671.
SIG_PROVENANCE_RESIDUE = {
  "sig/prism_node_children.rbs" => 1,
  "sig/rigor.rbs" => 51,
  "sig/rigor/analysis/baseline.rbs" => 5,
  "sig/rigor/analysis/check_rules/always_truthy_condition_collector.rbs" => 1,
  "sig/rigor/analysis/check_rules/dead_assignment_collector.rbs" => 1,
  "sig/rigor/analysis/dependency_source_inference/gem_resolver.rbs" => 1,
  "sig/rigor/analysis/fact_store.rbs" => 18,
  "sig/rigor/ast.rbs" => 1,
  "sig/rigor/cache.rbs" => 1,
  "sig/rigor/cli/diff_command.rbs" => 1,
  "sig/rigor/cli/explain_command.rbs" => 1,
  "sig/rigor/cli/sig_gen_command.rbs" => 2,
  "sig/rigor/cli/type_scan_command.rbs" => 1,
  "sig/rigor/environment.rbs" => 43,
  "sig/rigor/inference.rbs" => 95,
  "sig/rigor/inference/builtins/method_catalog.rbs" => 1,
  "sig/rigor/inference/void_origin.rbs" => 5,
  "sig/rigor/plugin.rbs" => 3,
  "sig/rigor/plugin/base.rbs" => 26,
  "sig/rigor/plugin/blueprint.rbs" => 3,
  "sig/rigor/plugin/fact_store.rbs" => 2,
  "sig/rigor/plugin/io_boundary.rbs" => 4,
  "sig/rigor/plugin/load_error.rbs" => 3,
  "sig/rigor/plugin/loader.rbs" => 4,
  "sig/rigor/plugin/manifest.rbs" => 21,
  "sig/rigor/plugin/registry.rbs" => 7,
  "sig/rigor/rbs_extended.rbs" => 23,
  "sig/rigor/reflection.rbs" => 9,
  "sig/rigor/scope.rbs" => 111,
  "sig/rigor/source.rbs" => 9,
  "sig/rigor/testing.rbs" => 4,
  "sig/rigor/trinary.rbs" => 4,
  "sig/rigor/type.rbs" => 209
}.freeze

module SigProvenanceSpecHelpers
  def provenance_failure(label, rows)
    lines = rows.map(&:to_s)
    shown = lines.first(SIG_PROVENANCE_LISTING_CAP)
    suffix = lines.size > shown.size ? "\n  … #{lines.size - shown.size} more" : ""
    "#{label}: #{lines.size} declaration(s)\n  #{shown.join("\n  ")}#{suffix}"
  end

  # Runs the whole classifier over a two-file fixture project, so a unit example exercises the same
  # join the corpus examples do rather than a parallel reimplementation of it.
  def audit_fixture(ruby:, rbs:)
    write_fixture("lib/fixture.rb", ruby)
    write_fixture("sig/fixture.rbs", rbs)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => ["lib"], "signature_paths" => [File.join(fixture_root, "sig")]
      )
    )
    SigProvenanceAuditor.audit(root: fixture_root, configuration: configuration)
  end

  def classifications_for(ruby:, rbs:, method: nil)
    audit_fixture(ruby: ruby, rbs: rbs)
      .reject { |row| row.classification == SigProvenanceAuditor::NON_METHOD }
      .select { |row| method.nil? || row.declaration.method_name == method }
      .map(&:classification)
  end

  def write_fixture(relative, contents)
    full = File.join(fixture_root, relative)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
  end
end

RSpec.describe "sig/ provenance (ADR-107 G3)" do
  include SigProvenanceSpecHelpers

  describe "the classifier (fixture projects, independent of the corpus)" do
    let(:fixture_root) { Dir.mktmpdir }

    after { FileUtils.remove_entry(fixture_root) }

    it "calls a declaration whose return is what sig-gen proves `generated`" do
      rows = classifications_for(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                                 rbs: "class Widget\n  def n: () -> 42\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::GENERATED])
    end

    it "calls the same declaration with a typed parameter `parameter_intent` (ADR-5 clause 2)" do
      rows = classifications_for(ruby: "class Widget\n  def n(x)\n    42\n  end\nend\n",
                                 rbs: "class Widget\n  def n: (Integer x) -> 42\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::PARAMETER_INTENT])
    end

    it "calls a constructor stub earned — sig-gen always spells `initialize` as `-> void`" do
      rows = classifications_for(ruby: "class Widget\n  def initialize(x)\n    @x = x\n  end\nend\n",
                                 rbs: "class Widget\n  def initialize: (Integer x) -> void\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::PARAMETER_INTENT])
    end

    it "calls a declaration sig-gen would narrow `tighter_return`" do
      rows = audit_fixture(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                           rbs: "class Widget\n  def n: () -> Integer\nend\n")
      row = rows.find { |r| r.declaration.method_name == "n" }
      expect(row.classification).to eq(SigProvenanceAuditor::TIGHTER_RETURN)
      expect(row).not_to be_marked
    end

    it "reads the gap marker off the member's RBS comment, and accepts #TBD" do
      rbs = "class Widget\n  # sig-gen gap: #TBD — the literal is not the contract.\n  " \
            "def n: () -> Integer\nend\n"
      row = audit_fixture(ruby: "class Widget\n  def n\n    42\n  end\nend\n", rbs: rbs)
            .find { |r| r.declaration.method_name == "n" }
      expect(row).to be_marked
      expect(row.declaration.marker).to eq("TBD")
    end

    it "does not read a marker out of an unrelated comment" do
      rbs = "class Widget\n  # A plain doc comment mentioning sig-gen and #825.\n  " \
            "def n: () -> Integer\nend\n"
      row = audit_fixture(ruby: "class Widget\n  def n\n    42\n  end\nend\n", rbs: rbs)
            .find { |r| r.declaration.method_name == "n" }
      expect(row).not_to be_marked
      expect(row.classification).to eq(SigProvenanceAuditor::TIGHTER_RETURN)
    end

    it "calls a declaration sig-gen will not swap `declared_divergent`" do
      rows = classifications_for(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                                 rbs: "class Widget\n  def n: () -> String\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::DECLARED_DIVERGENT])
    end

    it "calls a declaration whose body sig-gen cannot type `unrenderable`" do
      rows = classifications_for(ruby: "class Widget\n  def n(x)\n    x\n  end\nend\n",
                                 rbs: "class Widget\n  def n: (untyped x) -> Integer\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::UNRENDERABLE])
    end

    it "calls a declaration with no matching def `no_source`" do
      rows = classifications_for(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                                 rbs: "class Widget\n  def gone: () -> Integer\nend\n",
                                 method: "gone")
      expect(rows).to eq([SigProvenanceAuditor::NO_SOURCE])
    end

    it "leaves constants and type aliases out of scope as `non_method`" do
      rows = audit_fixture(ruby: "class Widget\n  def n\n    42\n  end\nend\n",
                           rbs: "class Widget\n  SIZE: Integer\n  type key = Symbol\n  def n: () -> 42\nend\n")
      expect(rows.map(&:classification)).to include(SigProvenanceAuditor::NON_METHOD)
      expect(rows.select { |r| r.classification == SigProvenanceAuditor::NON_METHOD }.size).to be >= 2
    end

    it "matches an RBS `self?.` module function against sig-gen's instance-side candidate" do
      rows = classifications_for(ruby: "module Widget\n  module_function\n\n  def n\n    42\n  end\nend\n",
                                 rbs: "module Widget\n  def self?.n: () -> 42\nend\n")
      expect(rows).to eq([SigProvenanceAuditor::GENERATED])
    end
  end

  describe "the classifier's two states the corpus does not currently reach" do
    def row_for(candidate, method: "n", return_rbs: "Integer")
      declaration = SigProvenanceAuditor::Declaration.new(
        path: "sig/widget.rbs", line: 2, class_name: "Widget", method_name: method,
        kind: :instance, typed_params: false, return_rbs: return_rbs, marker: nil
      )
      SigProvenanceAuditor.classify([declaration], [candidate]).first
    end

    def candidate(classification, **overrides)
      Rigor::SigGen::MethodCandidate.new(
        path: "lib/widget.rb", class_name: "Widget", method_name: :n, kind: :instance,
        classification: classification, **overrides
      )
    end

    it "calls an equivalent whose declared return sig-gen could not translate `untranslatable_declared`" do
      row = row_for(candidate(Rigor::SigGen::Classification::EQUIVALENT,
                              inferred_return: Rigor::Type::Combinator.nominal_of("Integer"),
                              declared_return_rbs: nil))
      expect(row.classification).to eq(SigProvenanceAuditor::UNTRANSLATABLE)
    end

    it "calls a non-constructor new-method `unmatched_declaration`" do
      row = row_for(candidate(Rigor::SigGen::Classification::NEW_METHOD,
                              inferred_return: Rigor::Type::Combinator.nominal_of("Integer")))
      expect(row.classification).to eq(SigProvenanceAuditor::UNMATCHED)
    end
  end

  describe "the corpus" do
    it "reads a non-empty sig tree (guards the glob against a tree reshuffle)" do
      paths = SigProvenanceAuditor.declarations(root: SIG_PROVENANCE_ROOT).map(&:path).uniq
      expect(paths.size).to be >= 30
      expect(paths).to include("sig/rigor.rbs")
    end

    it "carries a recorded-gap marker on every tighter-return (ADR-14's contradiction rule)" do
      unmarked = SIG_PROVENANCE_ROWS.select do |row|
        row.classification == SigProvenanceAuditor::TIGHTER_RETURN && !row.marked?
      end
      expect(unmarked).to be_empty, lambda {
        "#{provenance_failure('unmarked tighter-return', unmarked)}\n\n" \
          "sig-gen proposes a narrower return than each declaration says. Per ADR-14 either apply " \
          "the tightening, or record why it stays with a marker in the member's RBS comment:\n  " \
          "# sig-gen gap: #NNN — why sig-gen's proposal is not the contract\n" \
          "`#TBD` is accepted while the engine gap has no issue filed."
      }
    end

    it "keeps each file's hand-authored residue at its pinned count" do
      actual = SigProvenanceAuditor.residue_counts(SIG_PROVENANCE_ROWS)
      drift = (actual.keys | SIG_PROVENANCE_RESIDUE.keys).filter_map do |path|
        pinned = SIG_PROVENANCE_RESIDUE.fetch(path, 0)
        found = actual.fetch(path, 0)
        "  #{path}: #{found} (pinned #{pinned})" unless found == pinned
      end
      expect(drift).to be_empty, lambda {
        "#{drift.size} file(s) drifted from SIG_PROVENANCE_RESIDUE:\n#{drift.join("\n")}\n\n" \
          "A declaration that is neither generated-equivalent nor parameter intent is a gap " \
          "sig-gen could not close (ADR-107 § Decision). Mark it — a marker subtracts from the " \
          "count — or move the pin in this file with the reason in the commit body. A count that " \
          "DROPPED is an engine fix: lower the pin in the same commit."
      }
    end

    it "reports the residue as a total, so the number is visible without a failure" do
      expect(SIG_PROVENANCE_ROWS.count(&:residue?)).to eq(SIG_PROVENANCE_RESIDUE.values.sum)
    end
  end
end
