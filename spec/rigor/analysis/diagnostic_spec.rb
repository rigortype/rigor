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
      diagnostic = described_class.new(path: "f.rb", line: 1, column: 1, message: "x", rule: "flow.always-raises")
      expect(diagnostic.qualified_rule).to eq("flow.always-raises")
    end

    it "qualified_rule prefixes the source family for non-builtin diagnostics" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 1, message: "x", rule: "flow.always-raises",
        source_family: :rbs_extended
      )
      expect(diagnostic.qualified_rule).to eq("rbs_extended.flow.always-raises")
      expect(diagnostic.to_h).to include("source_family" => "rbs_extended", "rule" => "flow.always-raises")
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
        path: "f.rb", line: 1, column: 2, message: "boom", rule: "call.undefined-method"
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

  describe "structured receiver_type / method_name fields (ADR-23 slice 4)" do
    it "defaults both to nil" do
      diagnostic = described_class.new(path: "f.rb", line: 1, column: 1, message: "x")
      expect([diagnostic.receiver_type, diagnostic.method_name]).to eq([nil, nil])
    end

    it "carries the rendered receiver type and called method name" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 1, message: "undefined method `days' for Integer",
        rule: "call.undefined-method", receiver_type: "Integer", method_name: "days"
      )
      expect([diagnostic.receiver_type, diagnostic.method_name]).to eq(%w[Integer days])
    end
  end

  describe "project_definition_site field (ADR-17)" do
    it "defaults to nil and is omitted from to_h" do
      diagnostic = described_class.new(path: "f.rb", line: 1, column: 1, message: "x")
      expect(diagnostic.project_definition_site).to be_nil
      expect(diagnostic.to_h).not_to have_key("project_definition_site")
    end

    it "carries the project def site and serialises it when present" do
      diagnostic = described_class.new(
        path: "use.rb", line: 4, column: 15, message: "undefined method `shout' for \"hi\"",
        rule: "call.undefined-method", project_definition_site: "lib/core_ext.rb:4"
      )
      expect(diagnostic.project_definition_site).to eq("lib/core_ext.rb:4")
      expect(diagnostic.to_h).to include("project_definition_site" => "lib/core_ext.rb:4")
    end
  end

  describe ".from_node" do
    let(:node) { Prism.parse("  foo(:bar)").value.statements.body.first }

    it "derives 1-based line and start_column + 1 from the node location" do
      diagnostic = described_class.from_node(node, path: "demo.rb", message: "boom", rule: "x")
      expect(diagnostic.line).to eq(node.location.start_line)
      expect(diagnostic.column).to eq(node.location.start_column + 1)
      expect(diagnostic.path).to eq("demo.rb")
      expect(diagnostic.message).to eq("boom")
      expect(diagnostic.rule).to eq("x")
      expect(diagnostic.severity).to eq(:error)
    end

    it "forwards optional structured fields" do
      diagnostic = described_class.from_node(
        node, path: "demo.rb", message: "m", severity: :warning,
              source_family: "plugin.demo", receiver_type: "Foo", method_name: "bar"
      )
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.source_family).to eq("plugin.demo")
      expect(diagnostic.receiver_type).to eq("Foo")
      expect(diagnostic.method_name).to eq("bar")
    end
  end
end
