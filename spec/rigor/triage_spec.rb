# frozen_string_literal: true

require "rigor/triage"
require "rigor/analysis/diagnostic"

# ADR-23 — `Rigor::Triage` is pure over the diagnostic stream, so
# the aggregation and the six-recogniser catalogue are covered here
# with synthetic `Diagnostic` arrays (no Runner / no analysis pass).
RSpec.describe Rigor::Triage do
  def diag(path: "a.rb", rule: "call.undefined-method", message: "boom", severity: :error,
           receiver_type: nil, method_name: nil)
    Rigor::Analysis::Diagnostic.new(
      path: path, line: 1, column: 1, message: message, severity: severity, rule: rule,
      receiver_type: receiver_type, method_name: method_name
    )
  end

  def udm(method, receiver, **)
    diag(message: "undefined method `#{method}' for #{receiver}", **)
  end

  def hint(report, id)
    report.hints.find { |h| h.id == id }
  end

  describe ".analyze — distribution / hotspots / summary" do
    it "counts severities into the summary" do
      report = described_class.analyze([diag, diag(severity: :warning), diag(severity: :info)])
      expect([report.summary.total, report.summary.error,
              report.summary.warning, report.summary.info]).to eq([3, 1, 1, 1])
    end

    it "builds a rule distribution sorted by descending count" do
      diags = ([diag(rule: "r.a")] * 3) + ([diag(rule: "r.b")] * 5)
      rows = described_class.analyze(diags).distribution
      expect(rows.map { |r| [r.rule, r.count] }).to eq([["r.b", 5], ["r.a", 3]])
    end

    it "buckets rule-less diagnostics under the uncategorised sentinel" do
      rows = described_class.analyze([diag(rule: nil)]).distribution
      expect(rows.first.rule).to eq(Rigor::Triage::UNCATEGORISED)
    end

    it "ranks hotspot files by diagnostic count and caps at `top`" do
      diags = ([diag(path: "hot.rb")] * 4) + ([diag(path: "warm.rb")] * 2) + [diag(path: "cold.rb")]
      hotspots = described_class.analyze(diags, top: 2).hotspots
      expect(hotspots.map { |h| [h.file, h.count] }).to eq([["hot.rb", 4], ["warm.rb", 2]])
    end

    it "skips the catalogue when hints: false" do
      expect(described_class.analyze([udm("days", "5")] * 3, hints: false).hints).to be_empty
    end
  end

  describe "heuristic catalogue" do
    it "H1 — flags ActiveSupport core_ext selectors on core classes" do
      report = described_class.analyze([udm("days", "5"), udm("minutes", "10"), udm("squish", '"x"')])
      h = hint(report, "activesupport-core-ext")
      expect(h).not_to be_nil
      expect([h.confidence, h.diagnostic_count]).to eq([:likely, 3])
    end

    it "H2 — flags a method undefined across many files as a likely monkey-patch" do
      diags = %w[a.rb b.rb c.rb].map { |f| udm("frobnicate", "String", path: f) }
      h = hint(described_class.analyze(diags), "project-monkey-patch")
      expect(h).not_to be_nil
      expect([h.confidence, h.diagnostic_count]).to eq([:possible, 3])
    end

    it "H2 — does not fire below the cross-file threshold" do
      diags = %w[a.rb b.rb].map { |f| udm("frobnicate", "String", path: f) }
      expect(hint(described_class.analyze(diags), "project-monkey-patch")).to be_nil
    end

    it "H3 — surfaces the gems-without-RBS notice" do
      notice = diag(rule: "rbs.coverage.missing-gem", severity: :info,
                    message: "24 gem(s) in Gemfile.lock have no RBS available: ast, foo")
      h = hint(described_class.analyze([notice]), "gem-without-rbs")
      expect(h&.summary).to include("24 Gemfile.lock gem(s)")
    end

    it "H4 — flags ActiveRecord query methods on an Array[...] receiver" do
      report = described_class.analyze([udm("where", "Array[String]"), udm("joins", "Array[String]")])
      h = hint(report, "activerecord-relation-misinference")
      expect([h&.confidence, h&.diagnostic_count]).to eq([:possible, 2])
    end

    it "H4 — takes precedence over H2 for a known AR method across files" do
      diags = %w[a.rb b.rb c.rb].map { |f| udm("joins", "Array[String]", path: f) }
      report = described_class.analyze(diags)
      expect(hint(report, "activerecord-relation-misinference")).not_to be_nil
      expect(hint(report, "project-monkey-patch")).to be_nil
    end

    it "H5 — flags a systemic single-file cluster" do
      diags = Array.new(9) { diag(path: "big.rb", rule: "call.possible-nil-receiver") }
      h = hint(described_class.analyze(diags), "systemic-file-cluster")
      expect([h&.confidence, h&.diagnostic_count]).to eq([:likely, 9])
    end

    it "H6 — flags low-count scattered rules as likely genuine bugs" do
      diags = [diag(path: "x.rb", rule: "flow.dead-assignment"),
               diag(path: "y.rb", rule: "flow.dead-assignment")]
      h = hint(described_class.analyze(diags), "genuine-bugs")
      expect([h&.confidence, h&.diagnostic_count]).to eq([:likely, 2])
    end

    it "claims each diagnostic once — H1's cluster is not re-reported by H6" do
      report = described_class.analyze([udm("days", "5")] * 3)
      expect(hint(report, "activesupport-core-ext")).not_to be_nil
      expect(hint(report, "genuine-bugs")).to be_nil
    end
  end

  describe "WD3 — structured receiver_type / method_name fields (slice 4)" do
    # Carries the structured pair but a message the `undefined
    # method ...` parser cannot match — proves the recogniser reads
    # the fields rather than the message.
    def structured(method, receiver, **)
      diag(message: "(wording the message parser cannot match)",
           receiver_type: receiver, method_name: method, **)
    end

    it "H1 recognises a cluster from the structured fields alone" do
      report = described_class.analyze([structured("days", "Integer")] * 3)
      h = hint(report, "activesupport-core-ext")
      expect([h&.confidence, h&.diagnostic_count]).to eq([:likely, 3])
    end

    it "H4 reads the Array[...] receiver from the structured field" do
      report = described_class.analyze([structured("where", "Array[String]")])
      expect(hint(report, "activerecord-relation-misinference")).not_to be_nil
    end

    it "falls back to message parsing when the structured fields are absent" do
      report = described_class.analyze([udm("days", "5")] * 3)
      expect(hint(report, "activesupport-core-ext")).not_to be_nil
    end
  end

  describe ".report_to_h" do
    it "serialises the report to a JSON-ready Hash" do
      h = described_class.report_to_h(described_class.analyze([udm("days", "5")] * 3))
      expect(h.keys).to contain_exactly("summary", "distribution", "hotspots", "hints")
      expect(h["hints"].first["id"]).to eq("activesupport-core-ext")
    end
  end
end
