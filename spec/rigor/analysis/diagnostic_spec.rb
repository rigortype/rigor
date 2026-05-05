# frozen_string_literal: true

RSpec.describe Rigor::Analysis::Diagnostic do
  it "formats a stable human-readable diagnostic" do
    diagnostic = described_class.new(
      path: "lib/example.rb",
      line: 3,
      column: 7,
      message: "unexpected token",
      severity: :error
    )

    expect(diagnostic.to_s).to eq("lib/example.rb:3:7: error: unexpected token")
    expect(diagnostic.to_h).to include(
      "path" => "lib/example.rb",
      "line" => 3,
      "column" => 7,
      "severity" => "error"
    )
  end

  describe "source_family provenance (v0.0.8 slice 5)" do
    it "defaults source_family to :builtin" do
      diagnostic = described_class.new(path: "f.rb", line: 1, column: 1, message: "x", rule: "foo")
      expect(diagnostic.source_family).to eq(:builtin)
      expect(diagnostic.to_h).to include("source_family" => "builtin")
    end

    it "qualified_rule strips the prefix for builtin diagnostics" do
      diagnostic = described_class.new(path: "f.rb", line: 1, column: 1, message: "x", rule: "always-raises")
      expect(diagnostic.qualified_rule).to eq("always-raises")
    end

    it "qualified_rule prefixes the source family for non-builtin diagnostics" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 1, message: "x", rule: "always-raises",
        source_family: :rbs_extended
      )
      expect(diagnostic.qualified_rule).to eq("rbs_extended.always-raises")
      expect(diagnostic.to_h).to include("source_family" => "rbs_extended", "rule" => "always-raises")
    end

    it "qualified_rule handles plugin.<id>-style string source families" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 1, message: "x", rule: "no-mutation",
        source_family: "plugin.rigor-immutable"
      )
      expect(diagnostic.qualified_rule).to eq("plugin.rigor-immutable.no-mutation")
    end

    it "qualified_rule returns nil when rule itself is nil" do
      diagnostic = described_class.new(path: "f.rb", line: 1, column: 1, message: "parse error")
      expect(diagnostic.rule).to be_nil
      expect(diagnostic.qualified_rule).to be_nil
    end
  end

  describe "qualified-rule rendering in #to_s (v0.1.0 slice 5)" do
    it "leaves builtin diagnostics unchanged" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 2, message: "boom", rule: "undefined-method"
      )
      expect(diagnostic.to_s).to eq("f.rb:1:2: error: boom")
    end

    it "appends the qualified rule for non-builtin source families" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 2, message: "load failure",
        rule: "load-error", source_family: :plugin_loader
      )
      expect(diagnostic.to_s).to eq("f.rb:1:2: error: load failure [plugin_loader.load-error]")
    end

    it "renders plugin.<id>.<rule> prefixes for string source families" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 2, message: "frozen mutation",
        rule: "no-mutation", source_family: "plugin.rigor-immutable"
      )
      expect(diagnostic.to_s).to eq(
        "f.rb:1:2: error: frozen mutation [plugin.rigor-immutable.no-mutation]"
      )
    end

    it "leaves the message unchanged when rule is nil even with non-builtin source family" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 2, message: "internal",
        source_family: :rbs_extended
      )
      expect(diagnostic.to_s).to eq("f.rb:1:2: error: internal")
    end
  end
end
