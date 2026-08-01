# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/show_bleedingedge_command"

# ADR-50 § WD2 — `rigor show-bleedingedge` prints the bleeding-edge overlay and what the project's `bleeding_edge:`
# config adopts. The shipped overlay carries the queued next-major disciplines; a stubbed feature exercises the
# selector rendering independently of what ships.
RSpec.describe Rigor::CLI::ShowBleedingedgeCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv.dup, out: out, err: err).run
    [status, out.string, err.string]
  end

  describe "the shipped overlay" do
    it "lists the queued features in text, adopting none by default" do
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("Bleeding-edge overlay")
      expect(out).to include("reject-unparseable-signatures")
      expect(out).to include("Your configuration adopts: (none)")
    end

    it "emits the overlay as JSON with nothing active by default" do
      status, out, = run(["--format", "json"])
      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["overlay"].map { |f| f["id"] }).to include("reject-unparseable-signatures")
      expect(payload["active"]).to eq([])
      expect(payload["unknown_selected"]).to eq([])
    end
  end

  describe "with a project config that selects features" do
    let(:feature) do
      Rigor::BleedingEdge::Feature.new(
        id: "feat-a", summary: "promote flow.x", kind: :severity, severity_overrides: { "flow.x" => :error }
      )
    end

    before { stub_const("Rigor::BleedingEdge::FEATURES", [feature].freeze) }

    it "lists the overlay and the active selection" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "bleeding_edge:\n  - feat-a\n")
        status, out, = run(["--config", path])
        expect(status).to eq(0)
        expect(out).to include("feat-a")
        expect(out).to include("flow.x → :error")
        expect(out).to include("Your configuration adopts: feat-a")
      end
    end

    it "flags a selected id that is not in the overlay" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "bleeding_edge:\n  - ghost\n")
        _status, out, = run(["--config", path])
        expect(out).to include("Selected but not in this overlay (ignored): ghost")
      end
    end
  end

  # ADR-50 § WD2 — a behaviour feature has no severity diff to render, so the command has to make it legible
  # from its kind and summary alone; the whole point of the overlay is that what you adopt is inspectable.
  describe "with a behaviour feature queued" do
    let(:severity_feature) do
      Rigor::BleedingEdge::Feature.new(
        id: "feat-a", summary: "promote flow.x", kind: :severity, severity_overrides: { "flow.x" => :error }
      )
    end
    let(:behaviour_feature) do
      Rigor::BleedingEdge::Feature.new(
        id: "feat-b", summary: "count mutation survivors per site", kind: :behaviour
      )
    end

    before { stub_const("Rigor::BleedingEdge::FEATURES", [severity_feature, behaviour_feature].freeze) }

    it "renders both kinds in text, with no severity line for the behaviour one" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "bleeding_edge:\n  - feat-b\n")
        status, out, = run(["--config", path])
        expect(status).to eq(0)
        expect(out).to include("feat-a [severity]")
        expect(out).to include("feat-b [behaviour]")
        expect(out).to include("count mutation survivors per site")
        expect(out).to include("Your configuration adopts: feat-b")
        expect(out.lines.grep(/severity:/).join).to eq("    severity: flow.x → :error\n")
      end
    end

    it "renders both kinds in JSON, with the behaviour feature's severity map empty" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "bleeding_edge: true\n")
        status, out, = run(["--config", path, "--format", "json"])
        expect(status).to eq(0)
        payload = JSON.parse(out)
        expect(payload["overlay"]).to include(
          { "id" => "feat-b", "summary" => "count mutation survivors per site",
            "kind" => "behaviour", "severity_overrides" => {} }
        )
        expect(payload["overlay"].find { |f| f["id"] == "feat-a" }["kind"]).to eq("severity")
        expect(payload["active"]).to eq(%w[feat-a feat-b])
      end
    end
  end

  # ADR-50 § WD7. Nothing has graduated yet, so the section must stay invisible — today's output is the
  # baseline the manual documents.
  describe "graduated ids" do
    it "prints no section while the list is empty" do
      _status, out, = run([])
      expect(out).not_to include("Graduated")
      expect(JSON.parse(run(["--format", "json"])[1])["graduated"]).to eq([])
    end

    it "lists them once something has graduated" do
      stub_const("Rigor::BleedingEdge::GRADUATED", %w[feat-old].freeze)
      _status, out, = run([])
      expect(out).to include("Graduated — on by default, no longer selectable:")
      expect(out).to include("  feat-old")
      expect(JSON.parse(run(["--format", "json"])[1])["graduated"]).to eq(%w[feat-old])
    end
  end

  describe "a broken config" do
    it "reports a usage error rather than crashing" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".rigor.yml")
        File.write(path, "bleeding_edge: 42\n")
        status, _out, err = run(["--config", path])
        expect(status).to eq(Rigor::CLI::EXIT_USAGE)
        expect(err).to include("could not load configuration")
      end
    end
  end
end
