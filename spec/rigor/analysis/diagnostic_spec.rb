# frozen_string_literal: true

RSpec.describe Rigor::Analysis::Diagnostic do
  describe "position validation" do
    it "raises ArgumentError when line is below 1" do
      expect do
        described_class.new(path: "f.rb", line: 0, column: 1, message: "x")
      end.to raise_error(ArgumentError, /line must be >= 1/)
    end

    it "raises ArgumentError when column is below 1" do
      expect do
        described_class.new(path: "f.rb", line: 1, column: 0, message: "x")
      end.to raise_error(ArgumentError, /column must be >= 1/)
    end

    it "accepts line 1 and column 1 as valid" do
      diagnostic = described_class.new(path: "f.rb", line: 1, column: 1, message: "x")
      expect(diagnostic.line).to eq(1)
      expect(diagnostic.column).to eq(1)
    end
  end

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
      expect(diagnostic.to_s).to eq("f.rb:1:2: error: boom [call.undefined-method]")
    end

    # #431 — the identifier is what `# rigor:disable <id>` and `severity_profile:` are keyed on, and the
    # default output was the one place it could not be read. A builtin rule now carries it like every
    # other family; slice 5's exception for builtins was a layout call, not a judgment that it is noise.
    it "appends the bare rule for a builtin diagnostic" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 2, message: "boom", severity: :warning, rule: "flow.always-raises"
      )
      expect(diagnostic.to_s).to eq("f.rb:1:2: warning: boom [flow.always-raises]")
    end

    # The other half, and the reason `rule` is allowed to be nil: a parse error, a path error or an
    # internal analyzer error is produced by no rule, so there is nothing to suppress or configure and
    # nothing to print.
    it "leaves a rule-less diagnostic unsuffixed" do
      diagnostic = described_class.new(path: "f.rb", line: 1, column: 2, message: "cannot parse")
      expect(diagnostic.to_s).to eq("f.rb:1:2: error: cannot parse")
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

    it "serialises receiver_type / method_name to_h when present (jq-groupable, no message parse)" do
      diagnostic = described_class.new(
        path: "f.rb", line: 1, column: 1, message: "undefined method `days' for Integer",
        rule: "call.undefined-method", receiver_type: "Integer", method_name: "days"
      )
      expect(diagnostic.to_h).to include("receiver_type" => "Integer", "method_name" => "days")
    end

    it "omits receiver_type / method_name from to_h when nil" do
      diagnostic = described_class.new(path: "f.rb", line: 1, column: 1, message: "x")
      expect(diagnostic.to_h.keys).not_to include("receiver_type", "method_name")
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

  describe ".from_location" do
    let(:node) { Prism.parse("  foo(:bar)").value.statements.body.first }

    it "positions at an explicit sub-location (e.g. message_loc) with the 1-based column" do
      diagnostic = described_class.from_location(node.message_loc, path: "demo.rb", message: "m", rule: "x")
      expect(diagnostic.line).to eq(node.message_loc.start_line)
      expect(diagnostic.column).to eq(node.message_loc.start_column + 1)
    end

    it "is what from_node delegates to (whole-node location)" do
      via_node = described_class.from_node(node, path: "d.rb", message: "m")
      via_loc = described_class.from_location(node.location, path: "d.rb", message: "m")
      expect([via_node.line, via_node.column]).to eq([via_loc.line, via_loc.column])
    end
  end

  describe ".from_message_loc" do
    # A method call with a receiver: message_loc (the "foo" span) starts past the receiver, so it differs from the
    # receiver-spanning location.
    let(:call) { Prism.parse("receiver.foo(:bar)").value.statements.body.first }

    it "positions at the call's message_loc (the method-name span)" do
      diagnostic = described_class.from_message_loc(call, path: "d.rb", message: "m", rule: "x")
      expect(diagnostic.line).to eq(call.message_loc.start_line)
      expect(diagnostic.column).to eq(call.message_loc.start_column + 1)
      expect(diagnostic.column).not_to eq(call.location.start_column + 1)
    end

    it "falls back to node.location when message_loc is nil" do
      loc = Prism.parse("xyz").value.location
      node = instance_double(Prism::CallNode, message_loc: nil, location: loc)
      diagnostic = described_class.from_message_loc(node, path: "d.rb", message: "m")
      expect(diagnostic.line).to eq(loc.start_line)
      expect(diagnostic.column).to eq(loc.start_column + 1)
    end
  end

  describe ".from_name_loc" do
    # A def node: name_loc (the "foo" span) starts past the `def` keyword.
    let(:defn) { Prism.parse("def foo; end").value.statements.body.first }

    it "positions at the definition's name_loc (the declared-name span)" do
      diagnostic = described_class.from_name_loc(defn, path: "d.rb", message: "m")
      expect(diagnostic.line).to eq(defn.name_loc.start_line)
      expect(diagnostic.column).to eq(defn.name_loc.start_column + 1)
      expect(diagnostic.column).not_to eq(defn.location.start_column + 1)
    end

    it "falls back to node.location when name_loc is nil" do
      loc = Prism.parse("xyz").value.location
      node = instance_double(Prism::DefNode, name_loc: nil, location: loc)
      diagnostic = described_class.from_name_loc(node, path: "d.rb", message: "m")
      expect(diagnostic.line).to eq(loc.start_line)
      expect(diagnostic.column).to eq(loc.start_column + 1)
    end
  end

  describe "#error?" do
    it "is true only for :error severity" do
      base = { path: "f.rb", line: 1, column: 1, message: "m" }
      expect(described_class.new(**base, severity: :error).error?).to be(true)
      expect(described_class.new(**base, severity: :warning).error?).to be(false)
    end
  end
end
