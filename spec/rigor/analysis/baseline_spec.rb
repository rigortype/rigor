# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "rigor/analysis/baseline"
require "rigor/analysis/diagnostic"

RSpec.describe Rigor::Analysis::Baseline do
  def diagnostic(path:, rule:, message: "msg", source_family: :builtin)
    Rigor::Analysis::Diagnostic.new(
      path: path,
      line: 1,
      column: 1,
      message: message,
      severity: :error,
      rule: rule,
      source_family: source_family
    )
  end

  describe ".load" do
    it "returns nil when path is nil (no baseline configured)" do
      expect(described_class.load(nil)).to be_nil
    end

    it "returns an empty baseline when the path does not exist" do
      baseline = described_class.load("/nonexistent/path.yml")
      expect(baseline).to be_empty
    end

    it "loads rule-ID rows from a well-formed YAML file" do
      Tempfile.create(["baseline", ".yml"]) do |f|
        f.write(<<~YAML)
          version: 1
          ignored:
            - file: app/foo.rb
              rule: call.undefined-method
              count: 3
        YAML
        f.flush
        baseline = described_class.load(f.path)
        expect(baseline.size).to eq(1)
        expect(baseline.buckets.first.file).to eq("app/foo.rb")
        expect(baseline.buckets.first.rule).to eq("call.undefined-method")
        expect(baseline.buckets.first.count).to eq(3)
        expect(baseline.buckets.first.message_regex).to be_nil
      end
    end

    it "loads message-pattern rows and compiles the regex" do
      Tempfile.create(["baseline", ".yml"]) do |f|
        f.write(<<~YAML)
          version: 1
          ignored:
            - file: app/foo.rb
              rule: call.undefined-method
              message: "undefined method `merge' for Array"
              count: 1
        YAML
        f.flush
        baseline = described_class.load(f.path)
        expect(baseline.buckets.first.message_regex).to be_a(Regexp)
        expect(baseline.buckets.first.message_regex.source).to eq("undefined method `merge' for Array")
      end
    end

    it "raises LoadError on a missing version field" do
      Tempfile.create(["baseline", ".yml"]) do |f|
        f.write("ignored: []\n")
        f.flush
        expect { described_class.load(f.path) }.to raise_error(
          described_class::LoadError, /unsupported `version:/
        )
      end
    end

    it "raises LoadError on a missing `file:` in a row" do
      Tempfile.create(["baseline", ".yml"]) do |f|
        f.write(<<~YAML)
          version: 1
          ignored:
            - rule: call.undefined-method
              count: 1
        YAML
        f.flush
        expect { described_class.load(f.path) }.to raise_error(
          described_class::LoadError, /missing `file:`/
        )
      end
    end

    it "raises LoadError on a non-positive count" do
      Tempfile.create(["baseline", ".yml"]) do |f|
        f.write(<<~YAML)
          version: 1
          ignored:
            - file: app/foo.rb
              rule: call.undefined-method
              count: 0
        YAML
        f.flush
        expect { described_class.load(f.path) }.to raise_error(
          described_class::LoadError, /`count:` must be a positive Integer/
        )
      end
    end
  end

  describe ".from_diagnostics" do
    it "groups by (file, qualified_rule) in :rule mode" do
      diagnostics = [
        diagnostic(path: "a.rb", rule: "call.undefined-method", message: "foo"),
        diagnostic(path: "a.rb", rule: "call.undefined-method", message: "bar"),
        diagnostic(path: "b.rb", rule: "call.undefined-method", message: "baz")
      ]
      baseline = described_class.from_diagnostics(diagnostics, match_mode: :rule)
      expect(baseline.size).to eq(2) # 2 distinct (file, rule) pairs

      a_bucket = baseline.buckets.find { |b| b.file == "a.rb" }
      expect(a_bucket.count).to eq(2)
      expect(a_bucket.message_regex).to be_nil
    end

    it "groups by (file, rule, message) in :message mode and escapes regex metacharacters" do
      diagnostics = [
        diagnostic(path: "a.rb", rule: "call.undefined-method", message: "undefined method `merge' for Array"),
        diagnostic(path: "a.rb", rule: "call.undefined-method", message: "undefined method `merge' for Array"),
        diagnostic(path: "a.rb", rule: "call.undefined-method", message: "undefined method `name' for Hash")
      ]
      baseline = described_class.from_diagnostics(diagnostics, match_mode: :message)
      expect(baseline.size).to eq(2)

      merge_bucket = baseline.buckets.find { |b| b.message_regex.source.include?("merge") }
      expect(merge_bucket.count).to eq(2)
      # Confirm the regex round-trips correctly through escape +
      # match — the literal backtick / apostrophe / square-
      # brackets in the original message must NOT be
      # regex-interpreted.
      expect(merge_bucket.message_regex.match?("undefined method `merge' for Array")).to be(true)
    end

    it "picks up plugin diagnostics via qualified_rule (`source_family.rule`)" do
      diagnostics = [
        diagnostic(path: "a.rb", rule: "unknown-helper", source_family: "plugin.rails-routes")
      ]
      baseline = described_class.from_diagnostics(diagnostics)
      expect(baseline.buckets.first.rule).to eq("plugin.rails-routes.unknown-helper")
    end

    it "raises ArgumentError on an unknown match_mode" do
      expect { described_class.from_diagnostics([], match_mode: :line) }.to raise_error(ArgumentError)
    end
  end

  describe "#filter — WD4 ALL-or-NOTHING per bucket" do
    it "silences all diagnostics in a bucket when actual <= count" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method")
                                                  ])
      # 3 baselined; pass 3 again, all silenced.
      surfaced, silenced = baseline.filter([
                                             diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                             diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                             diagnostic(path: "a.rb", rule: "call.undefined-method")
                                           ])
      expect(surfaced).to be_empty
      expect(silenced).to eq(3)
    end

    it "surfaces ALL diagnostics in a bucket when actual > count (not just the excess)" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method")
                                                  ])
      # 3 baselined; pass 5 — ALL 5 surface, NOT the excess 2.
      diags = Array.new(5) { diagnostic(path: "a.rb", rule: "call.undefined-method") }
      surfaced, silenced = baseline.filter(diags)
      expect(surfaced.size).to eq(5)
      expect(silenced).to eq(0)
    end

    it "silences a bucket when actual is below count (drift opportunity)" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method")
                                                  ])
      # 3 baselined; pass 2 — under threshold, both silenced.
      diags = Array.new(2) { diagnostic(path: "a.rb", rule: "call.undefined-method") }
      surfaced, silenced = baseline.filter(diags)
      expect(surfaced).to be_empty
      expect(silenced).to eq(2)
    end

    it "surfaces diagnostics in a file with no baseline entry" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method")
                                                  ])
      surfaced, silenced = baseline.filter([
                                             diagnostic(path: "b.rb", rule: "call.undefined-method")
                                           ])
      expect(surfaced.size).to eq(1)
      expect(silenced).to eq(0)
    end

    it "treats message-pattern rows as tighter than rule-ID rows in the same file/rule pair" do
      # Pre-existing baseline: ONE message-pattern row (`merge`) + ONE rule-ID row.
      buckets = [
        described_class::Bucket.new(
          file: "a.rb", rule: "call.undefined-method",
          message_regex: Regexp.new(Regexp.escape("undefined method `merge'")), count: 1
        ),
        described_class::Bucket.new(
          file: "a.rb", rule: "call.undefined-method",
          message_regex: nil, count: 2
        )
      ]
      baseline = described_class.new(buckets)

      # Pass: 1× merge, 2× other-message → all match their respective buckets, all silenced.
      surfaced, silenced = baseline.filter([
                                             diagnostic(path: "a.rb", rule: "call.undefined-method",
                                                        message: "undefined method `merge' for Array"),
                                             diagnostic(path: "a.rb", rule: "call.undefined-method",
                                                        message: "undefined method `name' for X"),
                                             diagnostic(path: "a.rb", rule: "call.undefined-method",
                                                        message: "undefined method `host' for Y")
                                           ])
      expect(surfaced).to be_empty
      expect(silenced).to eq(3)
    end

    it "surfaces a diagnostic that matches no baseline row" do
      buckets = [
        described_class::Bucket.new(
          file: "a.rb", rule: "call.undefined-method",
          message_regex: Regexp.new(Regexp.escape("undefined method `merge'")), count: 1
        )
      ]
      baseline = described_class.new(buckets)

      surfaced, silenced = baseline.filter([
                                             diagnostic(path: "a.rb", rule: "call.undefined-method",
                                                        message: "undefined method `name' for X")
                                           ])
      expect(surfaced.size).to eq(1)
      expect(silenced).to eq(0)
    end
  end

  describe "#audit (slice 2 — drift inspection)" do
    it "classifies a bucket whose actual count equals the recorded count as :within" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method")
                                                  ])
      rows = baseline.audit(Array.new(3) { diagnostic(path: "a.rb", rule: "call.undefined-method") })
      expect(rows.first.status).to eq(:within)
      expect(rows.first.delta).to eq(0)
    end

    it "classifies a bucket whose actual count is zero as :cleared (prune candidate)" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method")
                                                  ])
      rows = baseline.audit([])
      expect(rows.first.status).to eq(:cleared)
      expect(rows.first.delta).to eq(-2)
    end

    it "classifies a bucket whose actual count is below recorded as :reducible (regenerate candidate)" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method")
                                                  ])
      rows = baseline.audit(Array.new(2) { diagnostic(path: "a.rb", rule: "call.undefined-method") })
      expect(rows.first.status).to eq(:reducible)
      expect(rows.first.delta).to eq(-3)
    end

    it "classifies a bucket whose actual count exceeds recorded as :over (CI regression)" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method")
                                                  ])
      rows = baseline.audit(Array.new(5) { diagnostic(path: "a.rb", rule: "call.undefined-method") })
      expect(rows.first.status).to eq(:over)
      expect(rows.first.delta).to eq(3)
    end

    it "ignores diagnostics that don't match any bucket (new findings are out of audit scope)" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method")
                                                  ])
      rows = baseline.audit([
                              diagnostic(path: "a.rb", rule: "call.undefined-method"),
                              diagnostic(path: "b.rb", rule: "nullable-receiver"),
                              diagnostic(path: "c.rb", rule: "wrong-arity")
                            ])
      expect(rows.size).to eq(1)
      expect(rows.first.bucket.file).to eq("a.rb")
      expect(rows.first.status).to eq(:within)
    end
  end

  describe "#without (slice 2 — prune helper)" do
    it "returns a new Baseline omitting the given buckets" do
      baseline = described_class.from_diagnostics([
                                                    diagnostic(path: "a.rb", rule: "call.undefined-method"),
                                                    diagnostic(path: "b.rb", rule: "wrong-arity")
                                                  ])
      first = baseline.buckets.first
      pruned = baseline.without([first])
      expect(pruned.size).to eq(1)
      expect(pruned.buckets).not_to include(first)
    end
  end

  describe "#to_yaml" do
    it "round-trips through load → diagnostics → from_diagnostics → to_yaml → load" do
      diagnostics = [
        diagnostic(path: "a.rb", rule: "call.undefined-method"),
        diagnostic(path: "a.rb", rule: "call.undefined-method"),
        diagnostic(path: "b.rb", rule: "nullable-receiver")
      ]
      baseline = described_class.from_diagnostics(diagnostics)
      yaml = baseline.to_yaml

      Tempfile.create(["baseline", ".yml"]) do |f|
        f.write(yaml)
        f.flush
        loaded = described_class.load(f.path)
        expect(loaded.size).to eq(2)
        expect(loaded.buckets.map(&:count).sort).to eq([1, 2])
      end
    end
  end
end
