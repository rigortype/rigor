# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/show_bleedingedge_command"

# ADR-50 § WD2 — `rigor show-bleedingedge` prints the bleeding-edge
# overlay and what the project's `bleeding_edge:` config adopts. The
# overlay is empty in this release, so the default run reports an empty
# set; a stubbed feature exercises the populated rendering.
RSpec.describe Rigor::CLI::ShowBleedingedgeCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv.dup, out: out, err: err).run
    [status, out.string, err.string]
  end

  describe "the empty overlay" do
    it "reports an empty overlay in text and exits 0" do
      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("Bleeding-edge overlay")
      expect(out).to include("empty in this release")
      expect(out).to include("Your configuration adopts: (none)")
    end

    it "emits an empty overlay as JSON" do
      status, out, = run(["--format", "json"])
      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload).to eq(
        "overlay" => [], "selector" => false, "active" => [], "unknown_selected" => []
      )
    end
  end

  describe "with a project config that selects features" do
    let(:feature) do
      Rigor::BleedingEdge::Feature.new(
        id: "feat-a", summary: "promote flow.x", severity_overrides: { "flow.x" => :error }
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
