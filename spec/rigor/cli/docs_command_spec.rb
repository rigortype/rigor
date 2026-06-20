# frozen_string_literal: true

require "stringio"

require "rigor/cli"
require "rigor/cli/docs_command"

# `rigor docs` serves the docs bundled with the gem OFFLINE (ADR-74).
# These examples exercise the real on-disk `docs/` tree so the contract
# an installed Rigor + the SKILL-driven UX depend on is verified
# end-to-end. The grammar mirrors `rigor skill`: the positional slot is
# a doc name; alternative outputs are flags (`--list` / `--path`).
RSpec.describe Rigor::CLI::DocsCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv.dup, out: out, err: err).run
    [status, out.string, err.string]
  end

  describe "index (no argument)" do
    it "prints the bundled llms.txt doc index" do
      status, out, = run([])
      expect(status).to eq(0)
      # ASCII-only assertions: the index is read with the external
      # encoding, so a non-ASCII substring (an em-dash) would clash.
      expect(out).to include("offline doc index")
      expect(out).to include("rigor docs <name>")
    end
  end

  describe "--list" do
    it "lists every bundled doc with an existing absolute path" do
      status, out, = run(["--list"])
      expect(status).to eq(0)
      expect(out).to include("install")
      expect(out).to include("manual/02-cli-reference")
      expect(out).to include("handbook/03-narrowing")
      out.each_line do |line|
        path = line.split("  ", 2).last.strip
        expect(File.file?(path)).to be(true), "expected #{path.inspect} to exist"
      end
    end

    it "filters to a single category" do
      status, out, = run(%w[--list handbook])
      expect(status).to eq(0)
      expect(out).to include("handbook/03-narrowing")
      expect(out).not_to include("manual/02-cli-reference")
    end

    it "errors on an unknown category" do
      status, _out, err = run(%w[--list bogus])
      expect(status).to eq(1)
      expect(err).to include("Unknown category: bogus")
      expect(err).to include("manual")
      expect(err).to include("handbook")
    end
  end

  describe "<name> (bare = print)" do
    it "prints the install guide with a provenance header" do
      status, out, = run(["install"])
      expect(status).to eq(0)
      expect(out).to start_with("<!-- rigor docs install ")
      expect(out).to include("Install Rigor")
    end

    it "accepts a chapter by its prefixed and stripped name" do
      _s1, prefixed, = run(["02-cli-reference"])
      _s2, stripped, = run(["cli-reference"])
      expect(prefixed).to include("CLI command reference")
      # The numeric-prefixed and stripped names resolve to the same page.
      expect(stripped).to eq(prefixed)
    end

    it "serves a handbook chapter by its category-qualified path" do
      status, out, = run(["handbook/03-narrowing"])
      expect(status).to eq(0)
      expect(out).to start_with("<!-- rigor docs 03-narrowing ")
    end

    it "errors with the qualified candidates on an ambiguous short name" do
      # `plugins` is a chapter slug in BOTH manual and handbook.
      status, _out, err = run(["plugins"])
      expect(status).to eq(1)
      expect(err).to include("Ambiguous doc name: plugins")
      expect(err).to include("manual/07-plugins")
      expect(err).to include("handbook/09-plugins")
    end

    it "resolves the new improvement-loop chapter" do
      status, out, = run(["17-driving-improvement"])
      expect(status).to eq(0)
      expect(out).to include("rigor-next-steps")
    end

    it "exits 1 with the available list on an unknown doc name" do
      status, _out, err = run(["no-such-doc"])
      expect(status).to eq(1)
      expect(err).to include("Unknown doc: no-such-doc")
      expect(err).to include("install")
    end
  end

  describe "--path <name>" do
    it "prints the absolute path on a single line" do
      status, out, = run(%w[--path editor-integration])
      expect(status).to eq(0)
      lines = out.strip.split("\n")
      expect(lines.size).to eq(1)
      expect(lines.first).to end_with("docs/manual/09-editor-integration.md")
      expect(File.file?(lines.first)).to be(true)
    end

    it "is a usage error when no name is given" do
      status, _out, err = run(["--path"])
      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("requires a doc name")
    end
  end

  describe "deprecated verb forms (removed in v0.3.0)" do
    it "still lists via `list` but warns on stderr" do
      status, out, err = run(["list"])
      expect(status).to eq(0)
      expect(out).to include("install")
      expect(err).to include("`list` is deprecated")
      expect(err).to include("v0.3.0")
      expect(err).to include("rigor docs --list")
    end

    it "still resolves a path via `path <name>` but warns on stderr" do
      status, out, err = run(%w[path editor-integration])
      expect(status).to eq(0)
      expect(out.strip).to end_with("docs/manual/09-editor-integration.md")
      expect(err).to include("`path <name>` is deprecated")
      expect(err).to include("rigor docs --path <name>")
    end
  end

  describe "help" do
    it "writes usage to stdout and exits 0" do
      status, out, = run(["help"])
      expect(status).to eq(0)
      expect(out).to include("Usage: rigor docs")
      expect(out).to include("--list")
    end
  end
end
