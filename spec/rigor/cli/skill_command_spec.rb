# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/skill_command"

# `rigor skill` exposes the SKILL.md files Rigor bundles under
# `skills/` (`rigor-project-init`, `rigor-baseline-reduce`,
# `rigor-plugin-author`). The integration-style examples here
# exercise the real on-disk skill directory so the contract the
# bundled skills + AI agents depend on is verified end-to-end.
RSpec.describe Rigor::CLI::SkillCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv.dup, out: out, err: err).run
    [status, out.string, err.string]
  end

  describe "list" do
    it "lists every bundled skill with its absolute SKILL.md path" do
      status, out, = run(["list"])
      expect(status).to eq(0)
      expect(out).to include("rigor-project-init")
      expect(out).to include("rigor-baseline-reduce")
      expect(out).to include("rigor-plugin-author")
      # Every listed path must point at an existing SKILL.md.
      out.each_line do |line|
        path = line.split("  ", 2).last.strip
        expect(File.file?(path)).to be(true), "expected #{path.inspect} to exist"
      end
    end

    it "is the default when no subcommand is given" do
      status_list, out_list, = run(["list"])
      status_default, out_default, = run([])
      expect(status_default).to eq(status_list)
      expect(out_default).to eq(out_list)
    end
  end

  describe "describe" do
    # `describe` probes the *current working directory*, so each
    # example sets up a throwaway project root and runs from inside it.
    def describe_in(files, argv = ["describe"])
      Dir.mktmpdir do |dir|
        files.each do |relative, contents|
          path = File.join(dir, relative)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, contents)
        end
        Dir.chdir(dir) { run(argv) }
      end
    end

    it "reports project state, a recommendation, the catalogue, and an agent prompt" do
      status, out, = describe_in({})
      expect(status).to eq(0)
      expect(out).to include("# Rigor — next steps for this project")
      expect(out).to include("rigortype #{Rigor::VERSION}")
      expect(out).to include("## Project state")
      expect(out).to include("## Recommended next step")
      expect(out).to include("## All skills you can run next")
      expect(out).to include("## For the agent")
      # P1-C: the agent prompt teaches check-aware routing (describe itself
      # stays presence-only — it never runs `rigor check`).
      expect(out).to include("refine the choice")
      expect(out).to include("→ rigor-baseline-reduce")
    end

    it "is reachable as the top-level `rigor describe` alias" do
      Dir.mktmpdir do |dir|
        sub = StringIO.new
        Dir.chdir(dir) { Rigor::CLI.new(%w[skill describe], out: sub, err: StringIO.new).run }
        aliased = StringIO.new
        Dir.chdir(dir) { Rigor::CLI.new(%w[describe], out: aliased, err: StringIO.new).run }
        expect(aliased.string).to eq(sub.string)
        expect(aliased.string).to include("# Rigor — next steps for this project")
      end
    end

    it "recommends rigor-project-init when there is no Rigor config" do
      _status, out, = describe_in({})
      expect(out).to include("\u2192 rigor-project-init \u2014")
      expect(out).to include("Config file:    none")
    end

    it "recommends rigor-ci-setup when configured but CI is not wired" do
      _status, out, = describe_in({ ".rigor.dist.yml" => "target_ruby: '3.3'\n" })
      expect(out).to include("\u2192 rigor-ci-setup \u2014")
    end

    it "recommends rigor-baseline-reduce when a baseline exists and CI is wired" do
      _status, out, = describe_in(
        {
          ".rigor.dist.yml" => "target_ruby: '3.3'\n",
          ".rigor-baseline.yml" => "version: 1\n",
          ".github/workflows/rigor.yml" => "jobs:\n  rigor:\n    steps:\n      - run: rigor check\n"
        }
      )
      expect(out).to include("\u2192 rigor-baseline-reduce \u2014")
    end

    it "recommends rigor-protection-uplift when configured + CI-wired with no baseline" do
      _status, out, = describe_in(
        {
          ".rigor.dist.yml" => "target_ruby: '3.3'\n",
          ".gitlab-ci.yml" => "rigor:\n  script: rigor check\n"
        }
      )
      expect(out).to include("\u2192 rigor-protection-uplift \u2014")
    end

    it "recommends rigor-rbs-setup when gems are present without community RBS" do
      _status, out, = describe_in(
        {
          ".rigor.dist.yml" => "target_ruby: '3.3'\n",
          "Gemfile.lock" => "GEM\n  specs:\n"
        }
      )
      expect(out).to include("\u2192 rigor-rbs-setup \u2014")
      expect(out).to include("Community RBS:  gems present, no collection")
    end

    it "stops recommending rigor-rbs-setup once the collection lockfile exists" do
      _status, out, = describe_in(
        {
          ".rigor.dist.yml" => "target_ruby: '3.3'\n",
          "Gemfile.lock" => "GEM\n  specs:\n",
          "rbs_collection.lock.yaml" => "sources: []\n"
        }
      )
      expect(out).not_to include("\u2192 rigor-rbs-setup \u2014")
      expect(out).to include("\u2192 rigor-ci-setup \u2014")
      expect(out).to include("Community RBS:  collection installed")
    end

    it "recommends rigor-editor-setup when an editor config lacks Rigor LSP wiring" do
      _status, out, = describe_in(
        {
          ".rigor.dist.yml" => "target_ruby: '3.3'\n",
          "Gemfile.lock" => "GEM\n  specs:\n",
          "rbs_collection.lock.yaml" => "sources: []\n",
          ".github/workflows/rigor.yml" => "jobs:\n  rigor:\n    steps:\n      - run: rigor check\n",
          ".vscode/settings.json" => "{ \"editor.tabSize\": 2 }\n"
        }
      )
      expect(out).to include("→ rigor-editor-setup —")
      expect(out).to include(".vscode present, Rigor LSP not wired")
    end

    it "stops recommending rigor-editor-setup once the editor config references rigor" do
      _status, out, = describe_in(
        {
          ".rigor.dist.yml" => "target_ruby: '3.3'\n",
          "Gemfile.lock" => "GEM\n  specs:\n",
          "rbs_collection.lock.yaml" => "sources: []\n",
          ".github/workflows/rigor.yml" => "jobs:\n  rigor:\n    steps:\n      - run: rigor check\n",
          ".vscode/settings.json" => "{ \"rigor.enable\": true }\n"
        }
      )
      expect(out).not_to include("→ rigor-editor-setup —")
      expect(out).to include("→ rigor-protection-uplift —")
    end

    it "recommends rigor-mcp-setup when an MCP client config lacks Rigor" do
      _status, out, = describe_in(
        {
          ".rigor.dist.yml" => "target_ruby: '3.3'\n",
          "Gemfile.lock" => "GEM\n  specs:\n",
          "rbs_collection.lock.yaml" => "sources: []\n",
          ".github/workflows/rigor.yml" => "jobs:\n  rigor:\n    steps:\n      - run: rigor check\n",
          ".mcp.json" => "{ \"mcpServers\": {} }\n"
        }
      )
      expect(out).to include("→ rigor-mcp-setup —")
      expect(out).to include("MCP config present, Rigor not wired")
    end

    it "stops recommending rigor-mcp-setup once the MCP config references rigor" do
      _status, out, = describe_in(
        {
          ".rigor.dist.yml" => "target_ruby: '3.3'\n",
          "Gemfile.lock" => "GEM\n  specs:\n",
          "rbs_collection.lock.yaml" => "sources: []\n",
          ".github/workflows/rigor.yml" => "jobs:\n  rigor:\n    steps:\n      - run: rigor check\n",
          ".mcp.json" => "{ \"mcpServers\": { \"rigor\": { \"command\": \"rigor\" } } }\n"
        }
      )
      expect(out).not_to include("→ rigor-mcp-setup —")
      expect(out).to include("→ rigor-protection-uplift —")
    end

    it "lists the downstream skills with a load command, excluding the entry point itself" do
      _status, out, = describe_in({})
      expect(out).to include("rigor skill print rigor-project-init")
      expect(out).to include("rigor skill print rigor-protection-uplift")
      # The catalogue heading section must not advertise the entry point.
      catalogue = out.split("## All skills you can run next", 2).last.to_s
      expect(catalogue).not_to include("- rigor-next-steps —")
    end

    it "lists the catalogue-only maintenance / validation skills too" do
      _status, out, = describe_in({})
      catalogue = out.split("## All skills you can run next", 2).last.to_s
      %w[
        rigor-rbs-setup rigor-monkeypatch-resolve rigor-editor-setup rigor-mcp-setup
        rigor-plugin-tune rigor-upgrade rigor-doctor
      ].each do |name|
        expect(catalogue).to include("rigor skill print #{name}"), "expected catalogue to list #{name}"
      end
    end

    it "accepts the --describe flag spelling identically to the describe subcommand" do
      Dir.mktmpdir do |dir|
        sub = Dir.chdir(dir) { run(["describe"]) }
        flag = Dir.chdir(dir) { run(["--describe"]) }
        expect(flag).to eq(sub)
      end
    end
  end

  describe "print" do
    it "prints a header followed by the SKILL.md body" do
      status, out, = run(%w[print rigor-project-init])
      expect(status).to eq(0)
      expect(out).to start_with("# Rigor skill: rigor-project-init\n")
      expect(out).to include("# Source:")
      expect(out).to include("rigor-project-init/SKILL.md")
      expect(out).to include("# References:")
      expect(out).to include("rigor-project-init/references/")
      # The SKILL frontmatter is intact — agents parse it.
      expect(out).to include("\n---\nname: rigor-project-init\n")
    end

    it "exits 1 with the available list on an unknown skill name" do
      status, _out, err = run(%w[print no-such-skill])
      expect(status).to eq(1)
      expect(err).to include("Unknown skill: no-such-skill")
      expect(err).to include("rigor-project-init")
    end

    it "is a usage error when no name is given" do
      status, _out, err = run(["print"])
      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("requires a skill name")
    end
  end

  describe "path" do
    it "prints the absolute SKILL.md path on a single line" do
      status, out, = run(%w[path rigor-baseline-reduce])
      expect(status).to eq(0)
      lines = out.strip.split("\n")
      expect(lines.size).to eq(1)
      expect(lines.first).to end_with("rigor-baseline-reduce/SKILL.md")
      expect(File.file?(lines.first)).to be(true)
    end

    it "exits 1 on an unknown skill name" do
      status, _out, err = run(%w[path no-such-skill])
      expect(status).to eq(1)
      expect(err).to include("Unknown skill: no-such-skill")
    end
  end

  describe "unknown subcommand" do
    it "writes usage to stderr and returns EXIT_USAGE" do
      status, _out, err = run(["bogus"])
      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("Unknown subcommand: bogus")
      expect(err).to include("Usage: rigor skill")
    end
  end

  describe "help" do
    it "writes usage to stdout and exits 0" do
      status, out, = run(["help"])
      expect(status).to eq(0)
      expect(out).to include("Usage: rigor skill")
      expect(out).to include("print <name>")
    end
  end
end
