# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/unused_command"

# ADR-102 — the report end to end, pinned where the fast template scan must not drift from the
# semantics it replaced: a template mention is a SUBSTRING test over the file's text, so a name
# inside a longer identifier still demotes, and a capital-free file can demote nothing.
RSpec.describe Rigor::CLI::UnusedCommand do
  def run_in(dir, *argv)
    out = StringIO.new
    err = StringIO.new
    status = Dir.chdir(dir) { described_class.new(argv: ["--format=json", *argv], out: out, err: err).run }
    [status, JSON.parse(out.string), err.string]
  end

  def write_project(dir, extra_source: nil)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, ".rigor.yml"), "paths:\n  - lib\n")
    File.write(File.join(dir, "lib/loner.rb"), "class Loner\nend\n")
    File.write(File.join(dir, "lib/extra.rb"), extra_source) if extra_source
  end

  describe "template mentions (ADR-102 WD4)" do
    it "demotes a declaration named inside a longer identifier — substring, not token, semantics" do
      Dir.mktmpdir do |dir|
        write_project(dir)
        File.write(File.join(dir, "config.yml"), "widget: LonerRegistry\n")

        status, report, = run_in(dir)

        expect(status).to eq(0)
        row = report.fetch("undecidable").find { |u| u.fetch("name") == "Loner" }
        expect(row).not_to be_nil
        expect(row.fetch("reason")).to include("config.yml")
        expect(report.fetch("candidates").map { |c| c.fetch("name") }).not_to include("Loner")
      end
    end

    it "spans a mention split around punctuation the way the raw text reads it" do
      Dir.mktmpdir do |dir|
        write_project(dir, extra_source: "module Ns\n  class Deep\n  end\nend\n")
        File.write(File.join(dir, "config.yml"), %(entry: "Ns::Deep"\n))

        _, report, = run_in(dir)

        expect(report.fetch("undecidable").map { |u| u.fetch("name") }).to include("Ns::Deep")
      end
    end

    it "keeps the candidate when the name never appears, even in capital-free prose that echoes it" do
      Dir.mktmpdir do |dir|
        write_project(dir)
        File.write(File.join(dir, "config.yml"), "note: the loner registry stays lowercase\n")

        _, report, = run_in(dir)

        expect(report.fetch("candidates").map { |c| c.fetch("name") }).to include("Loner")
        expect(report.fetch("undecidable")).to be_empty
      end
    end
  end
end
