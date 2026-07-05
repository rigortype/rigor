# frozen_string_literal: true

require "rigor/triage"
require "rigor/analysis/diagnostic"

# ADR-23 — `Rigor::Triage` is pure over the diagnostic stream, so the aggregation and the six-recogniser catalogue are
# covered here with synthetic `Diagnostic` arrays (no Runner / no analysis pass).
RSpec.describe Rigor::Triage do
  # normalize_receiver is a private module_function — exercised indirectly through selectors and directly via .send for
  # the patterns that build_selectors does not reach with synthetic data.
  def normalize_receiver(token)
    described_class.send(:normalize_receiver, token)
  end

  def diag(path: "a.rb", rule: "call.undefined-method", message: "boom", severity: :error,
           receiver_type: nil, method_name: nil, project_definition_site: nil)
    Rigor::Analysis::Diagnostic.new(
      path: path, line: 1, column: 1, message: message, severity: severity, rule: rule,
      receiver_type: receiver_type, method_name: method_name,
      project_definition_site: project_definition_site
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

  describe "WD6 — info excluded from the volume views by default" do
    # A real Rails project's info is dominated by plugin recognition trace (model-call / helper / …) — positive
    # "resolved this call" records, not problems. The volume views must route only the actionable error/warning signal
    # by default.
    def trace(rule, path: "a.rb", method_name: nil)
      diag(rule: rule, severity: :info, method_name: method_name, path: path)
    end

    it "excludes info from the distribution by default but keeps it in the summary" do
      report = described_class.analyze(([diag, trace("plugin.activerecord.model-call")] * 1) +
                                       ([trace("plugin.activerecord.model-call")] * 4))
      expect(report.summary.info).to eq(5)
      expect(report.distribution.map(&:rule)).to eq(["call.undefined-method"])
      expect(report.include_info).to be(false)
    end

    it "routes info into the distribution under include_info: true" do
      report = described_class.analyze([diag, trace("plugin.activerecord.model-call")],
                                       include_info: true)
      expect(report.distribution.map(&:rule))
        .to contain_exactly("call.undefined-method", "plugin.activerecord.model-call")
      expect(report.include_info).to be(true)
    end

    it "keeps info off the hotspot ranking so working code does not rank as a hotspot" do
      diags = ([trace("plugin.rails-routes.helper", path: "busy.rb")] * 9) +
              [diag(path: "buggy.rb")]
      hotspots = described_class.analyze(diags).hotspots
      expect(hotspots.map(&:file)).to eq(["buggy.rb"])
    end

    it "keeps info out of the selectors axis by default" do
      diags = [trace("plugin.actionpack.helper-call", method_name: "users_path")] * 3
      expect(described_class.analyze(diags).selectors).to be_empty
      expect(described_class.analyze(diags, include_info: true).selectors).not_to be_empty
    end

    it "still fires the gem-without-rbs hint from the info notice (hints see the full stream)" do
      notice = diag(rule: "rbs.coverage.missing-gem", severity: :info,
                    message: "3 gem(s) in Gemfile.lock have no RBS available: a, b, c")
      expect(hint(described_class.analyze([notice]), "gem-without-rbs")).not_to be_nil
    end

    it "does not let recognition-trace info read as a systemic cluster (H5) or genuine bug (H6)" do
      cluster = Array.new(9) { trace("plugin.activerecord.model-call", path: "models.rb") }
      report = described_class.analyze(cluster)
      expect(hint(report, "systemic-file-cluster")).to be_nil
      expect(hint(report, "genuine-bugs")).to be_nil
    end

    it "lets H5/H6 see info again under include_info: true" do
      cluster = Array.new(9) { trace("plugin.activerecord.model-call", path: "models.rb") }
      report = described_class.analyze(cluster, include_info: true)
      expect(hint(report, "systemic-file-cluster")).not_to be_nil
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

    it "H2K — flags an engine-proven project patch and names the defining file" do
      d = udm("shout", "String", path: "use.rb", project_definition_site: "lib/core_ext.rb:4")
      h = hint(described_class.analyze([d]), "project-monkey-patch-known")
      expect([h&.confidence, h&.diagnostic_count]).to eq([:likely, 1])
      expect(h.action).to include("lib/core_ext.rb")
    end

    it "H2K — takes precedence over H2 and the genuine-bug catch-all" do
      d = udm("shout", "String", path: "use.rb", project_definition_site: "lib/core_ext.rb:4")
      report = described_class.analyze([d])
      expect(hint(report, "project-monkey-patch-known")).not_to be_nil
      expect(hint(report, "project-monkey-patch")).to be_nil
      expect(hint(report, "genuine-bugs")).to be_nil
    end

    it "H7 — flags unresolved toplevel calls and points at pre_eval" do
      diags = %w[helper_one helper_two].map do |m|
        diag(rule: "call.unresolved-toplevel", severity: :warning, method_name: m,
             message: "unresolved toplevel call to `#{m}`")
      end
      h = hint(described_class.analyze(diags), "unresolved-toplevel")
      expect([h&.confidence, h&.diagnostic_count]).to eq([:possible, 2])
      expect(h.summary).to include("helper_one")
    end
  end

  describe "WD3 — structured receiver_type / method_name fields (slice 4)" do
    # Carries the structured pair but a message the `undefined method ...` parser cannot match — proves the recogniser
    # reads the fields rather than the message.
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

  describe ".analyze — selectors (class/method axis)" do
    it "groups by the structured (receiver_type, method_name) pair, not the message" do
      diags = [
        diag(rule: "call.undefined-method", receiver_type: "String", method_name: "squish",
             message: "(opaque)", path: "a.rb"),
        diag(rule: "call.undefined-method", receiver_type: "String", method_name: "squish",
             message: "(opaque)", path: "b.rb"),
        diag(rule: "call.argument-type-mismatch", receiver_type: "String", method_name: "squish",
             message: "(opaque)", path: "a.rb")
      ]
      sel = described_class.analyze(diags).selectors.first
      expect([sel.receiver, sel.method_name, sel.count, sel.files]).to eq(["String", "squish", 3, 2])
      expect(sel.rules).to eq("call.undefined-method" => 2, "call.argument-type-mismatch" => 1)
    end

    it "keeps a null receiver for method-only diagnostics and still groups by method" do
      diags = [diag(rule: "def.return-type-mismatch", method_name: "build", message: "x"),
               diag(rule: "def.return-type-mismatch", method_name: "build", message: "x")]
      sel = described_class.analyze(diags).selectors.first
      expect([sel.receiver, sel.method_name, sel.count]).to eq([nil, "build", 2])
    end

    it "ignores diagnostics with no method_name (flow / ivar rules carry no selector)" do
      expect(described_class.analyze([diag(rule: "flow.dead-assignment", method_name: nil)]).selectors).to be_empty
    end

    it "sorts selectors by descending count" do
      diags = [diag(method_name: "a")] + ([diag(method_name: "b")] * 3)
      expect(described_class.analyze(diags).selectors.map(&:method_name)).to eq(%w[b a])
    end

    describe "normalize_receiver (private helper)" do
      it "folds singleton(Name) to Name" do
        expect(normalize_receiver("singleton(Integer)")).to eq("Integer")
      end

      it "keeps a generic Array[...] form intact" do
        expect(normalize_receiver("Array[String]")).to eq("Array[String]")
      end

      it "extracts the nominal from Name[...]" do
        expect(normalize_receiver("Hash[Symbol, String]")).to eq("Hash")
      end

      it "returns nil for an unrecognised token" do
        expect(normalize_receiver(nil)).to be_nil
        expect(normalize_receiver("String | Integer")).to be_nil
      end
    end
  end

  describe "build_summary — absent severity keys" do
    it "defaults to zero for severities not present in the diagnostics" do
      report = described_class.analyze([diag(severity: :warning)])
      expect([report.summary.error, report.summary.info]).to all(eq(0))
    end

    it "kills a nil-injected default by asserting zero on an absent-key fetch" do
      report = described_class.analyze([diag(severity: :error)])
      expect(report.summary.warning).to eq(0)
    end
  end

  describe ".report_to_h" do
    it "serialises the report to a JSON-ready Hash" do
      h = described_class.report_to_h(described_class.analyze([udm("days", "5")] * 3))
      expect(h.keys).to contain_exactly("summary", "distribution", "selectors", "hotspots",
                                        "hints", "include_info")
      expect(h["hints"].first["id"]).to eq("activesupport-core-ext")
    end

    it "serialises each selector with receiver / method / count / files / rules" do
      diags = [diag(rule: "call.undefined-method", receiver_type: "Integer",
                    method_name: "days", message: "x")] * 2
      h = described_class.report_to_h(described_class.analyze(diags))
      expect(h["selectors"].first).to eq(
        "receiver" => "Integer", "method" => "days", "count" => 2, "files" => 1,
        "rules" => { "call.undefined-method" => 2 }
      )
    end
  end
end
