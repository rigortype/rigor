# frozen_string_literal: true

require "spec_helper"

require "rigor/analysis/runner"
require "rigor/configuration"

# ADR-130 slice 2 / ADR-128 WD6 (#2686) — `plugin.api-surface`, against this repository's own `sig/`
# (`sig/rigor/plugin/interfaces.rbs` and `base.rbs`). The fixture marks each line the examples read with
# `# surface: <name>`.
RSpec.describe "plugin.api-surface" do
  let(:fixture_dir) { File.expand_path("fixtures/plugin_api_surface", __dir__) }
  let(:sig_root) { File.expand_path("../../sig", __dir__) }

  def marks
    Dir.glob("lib/*.rb", base: fixture_dir).each_with_object({}) do |path, acc|
      File.readlines(File.join(fixture_dir, path)).each_with_index do |line, index|
        name = line[/# surface: (\S+)/, 1]
        acc[name] = [path, index + 1] if name
      end
    end
  end

  # `{ mark name => ["rule: message", ...] }` for every diagnostic on a marked line.
  def run_check(bleeding_edge: false)
    settings = Rigor::Configuration::DEFAULTS.merge(
      "paths" => %w[lib], "signature_paths" => [sig_root, "sig"], "parallel" => { "workers" => 0 },
      "bleeding_edge" => bleeding_edge
    )
    runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new(settings), cache_store: nil,
                                         workers: 0)
    rows = Dir.chdir(fixture_dir) { guarded_run(runner) }.to_h.fetch("diagnostics")
    by_site = rows.group_by { |row| [row.fetch("path"), row.fetch("line")] }
    marks.transform_values do |site|
      (by_site[site] || []).map { |row| "#{row.fetch('rule')}: #{row.fetch('message')}" }
    end
  end

  def surface_rows(rows) = rows.select { |row| row.start_with?("plugin.api-surface: ") }

  context "with the plugin-api-surface feature" do
    let(:rows) { run_check(bleeding_edge: ["plugin-api-surface"]) }

    it "reports a call to a member the interface does not declare, naming the interface and the method" do
      message = "plugin.api-surface: `discovered_method?' is not part of the plugin API: " \
                "`Rigor::Plugin::_Scope' does not declare it. The engine object answers it today, but Rigor does " \
                "not promise to keep it; call a member the interface declares (sig/rigor/plugin/interfaces.rbs) " \
                "or a public namespace (docs/internal-spec/public-api.md)"
      expect(rows.fetch("undeclared")).to eq([message])
      expect(surface_rows(rows.fetch("undeclared-environment")).join)
        .to include("`class_ordering' is not part of the plugin API: `Rigor::Plugin::_Environment'")
    end

    it "reports on a receiver that may be nil, judging its interface arm" do
      expect(surface_rows(rows.fetch("nilable-receiver")).size).to eq(1)
    end

    it "reports through a project base class" do
      expect(surface_rows(rows.fetch("indirect")).size).to eq(1)
    end

    it "is silent on a declared member and on every object's own surface" do
      expect(rows.fetch("declared")).to be_empty
      expect(rows.fetch("object-member")).to be_empty
    end

    # ADR-130 WD1 and #2817: where the facet is lost the value reads `Dynamic[top]`, and the rule has nothing to read.
    it "is silent where the facet is lost at a join or through safe navigation" do
      expect(rows.fetch("lost-at-join")).to be_empty
      expect(rows.fetch("lost-through-safe-navigation")).to be_empty
      expect(rows.fetch("untyped-helper")).to be_empty
    end

    it "is silent outside plugin source and in Rigor::Plugin::Base's own body" do
      expect(rows.fetch("not-a-plugin")).to be_empty
      expect(rows.fetch("engine-base")).to be_empty
    end
  end

  it "is silent by default" do
    rows = run_check
    expect(rows.values.flatten.grep(/\Aplugin\.api-surface/)).to be_empty
    expect(rows.fetch("undeclared")).to be_empty
  end

  # ADR-128 WD5: the seam does not arise while the value is untyped to assignability (ADR-130).
  it "accepts the hook scope where Rigor::Reflection takes `scope: Scope`" do
    rows = run_check(bleeding_edge: true)

    expect(rows.fetch("seam")).to be_empty
    expect(rows.fetch("seam-optional")).to be_empty
  end

  describe "node_rule's block binding" do
    let(:rows) { run_check }

    it "binds untyped from a class argument it cannot read, so no member reports" do
      expect(rows.fetch("unknown-class")).to be_empty
      expect(rows.fetch("unknown-class-type")).to eq(["dump.type: dump_type: Dynamic[top]"])
    end

    it "binds the class argument's instances where no overload names the class" do
      expect(rows.fetch("no-overload-class")).to be_empty
      expect(rows.fetch("no-overload-class-miss"))
        .to eq(["call.undefined-method: undefined method `not_a_member' for Prism::IfNode"])
    end

    it "binds a union of class objects to the union of their instances" do
      expect(rows.fetch("class-union-type")).to eq(["dump.type: dump_type: Prism::IfNode | Prism::UnlessNode"])
    end

    it "binds untyped from a union with a member that is not a class object, keeping the other parameters" do
      expect(rows.fetch("mixed-union-type")).to eq(["dump.type: dump_type: Dynamic[top]"])
      expect(rows.fetch("mixed-union-scope")).to eq(["dump.type: dump_type: Dynamic[Rigor::Plugin::_Scope]"])
    end

    it "keeps an overload's own class and the other block parameters" do
      expect(rows.fetch("overload-class")).to be_empty
      expect(rows.fetch("no-overload-class-scope")).to eq(["dump.type: dump_type: Dynamic[Rigor::Plugin::_Scope]"])
    end

    it "rebinds neither another Base hook nor a project's own node_rule" do
      expect(rows.fetch("other-hook")).to eq(["dump.type: dump_type: Prism::ProgramNode"])
      expect(rows.fetch("own-node-rule")).to eq(["dump.type: dump_type: Prism::Node"])
    end
  end
end
