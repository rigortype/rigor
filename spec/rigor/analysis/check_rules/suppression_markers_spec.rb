# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::Suppression}'s parsing and filtering on plain data: Prism comments and
# hand-built diagnostics, no runner. `suppression_spec.rb` pins the same behaviour end to end.
RSpec.describe Rigor::Analysis::CheckRules::Suppression do
  def comments_of(source)
    Prism.parse(source).comments
  end

  def diagnostic(line:, rule:, path: "a.rb", source_family: :builtin)
    Rigor::Analysis::Diagnostic.new(
      path: path, line: line, column: 1, message: "m", severity: :error, rule: rule, source_family: source_family
    )
  end

  describe ".parse_suppression_comments" do
    it "keys a line marker by its own line and a file marker for the whole file" do
      line_rules, file_rules = described_class.parse_suppression_comments(
        comments_of("x # rigor:disable call.undefined-method, flow.always-raises\n# rigor:disable-file def.foo\n")
      )

      expect(line_rules[1]).to eq(Set["call.undefined-method", "flow.always-raises"])
      expect(file_rules).to eq(Set["def.foo"])
    end

    it "reads a marker only when it opens the comment" do
      line_rules, file_rules = described_class.parse_suppression_comments(
        comments_of("x # see `# rigor:disable call.undefined-method`\n")
      )

      expect(line_rules).to be_empty
      expect(file_rules).to be_empty
    end
  end

  describe ".filter_suppressed" do
    let(:rows) do
      [diagnostic(line: 1, rule: "call.undefined-method"), diagnostic(line: 2, rule: "call.undefined-method")]
    end

    it "drops the rows a line marker covers and keeps the rest" do
      kept = described_class.filter_suppressed(
        rows, comments: comments_of("x # rigor:disable call.undefined-method\ny\n"), disabled_rules: []
      )

      expect(kept.map(&:line)).to eq([2])
    end

    it "drops every row for `all` in a file marker" do
      kept = described_class.filter_suppressed(
        rows, comments: comments_of("# rigor:disable-file all\n"), disabled_rules: []
      )

      expect(kept).to be_empty
    end

    it "drops the rows the project `disable:` list names" do
      kept = described_class.filter_suppressed(rows, comments: [], disabled_rules: ["call.undefined-method"])

      expect(kept).to be_empty
    end

    it "never drops a row with no rule" do
      kept = described_class.filter_suppressed(
        [diagnostic(line: 1, rule: nil)], comments: comments_of("# rigor:disable-file all\n"), disabled_rules: []
      )

      expect(kept.size).to eq(1)
    end
  end

  describe ".filter_plugin_suppressed" do
    it "answers only to a `plugin.<id>` or `plugin.<id>.<rule>` token, never to `all`" do
      row = diagnostic(line: 1, rule: "rule", source_family: :"plugin.x")

      bare = comments_of("x # rigor:disable all\n")
      qualified = comments_of("x # rigor:disable plugin.x.rule\n")

      expect(described_class.filter_plugin_suppressed([row], path: "a.rb", comments: bare)).to eq([row])
      expect(described_class.filter_plugin_suppressed([row], path: "a.rb", comments: qualified)).to be_empty
    end

    it "honours a file-level marker naming the whole plugin" do
      row = diagnostic(line: 3, rule: "rule", source_family: :"plugin.x")
      comments = comments_of("# rigor:disable-file plugin.x\n")

      expect(described_class.filter_plugin_suppressed([row], path: "a.rb", comments: comments)).to be_empty
    end
  end

  describe ".suppression_marker_diagnostics" do
    def rules(source)
      described_class.suppression_marker_diagnostics("a.rb", comments_of(source)).map(&:rule)
    end

    it "flags a token that matches no rule, an empty marker and an unrecognised marker word" do
      expect(rules("x # rigor:disable call.undefined-metod\n")).to eq(["suppression.unknown-rule"])
      expect(rules("x # rigor:disable\n")).to eq(["suppression.empty"])
      expect(rules("x # rigor:disable-next-line call.undefined-method\n")).to eq(["suppression.unknown-marker"])
    end

    it "is silent for a known token and for prose that quotes a marker" do
      expect(rules("x # rigor:disable call.undefined-method\n")).to be_empty
      expect(rules("x # a `# rigor:disable` note\n")).to be_empty
    end
  end
end
