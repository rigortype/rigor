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
    backdate(dir)
  end

  # The scan cache refuses to record a file modified within its racy window, so fixtures written
  # milliseconds before the run must be aged or nothing would be cached to serve.
  def backdate(dir)
    aged = Time.now - 10
    Dir.glob(File.join(dir, "**/*")).each { |f| File.utime(aged, aged, f) if File.file?(f) }
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

  describe "the per-file scan cache" do
    it "serves the second run without re-scanning an unchanged file, with an identical report" do
      Dir.mktmpdir do |dir|
        write_project(dir)
        File.write(File.join(dir, "config.yml"), "widget: LonerRegistry\n")
        backdate(dir)
        scans = 0
        allow(Rigor::Analysis::Reachability::Scan).to receive(:call).and_wrap_original do |original, **kwargs|
          scans += 1
          original.call(**kwargs)
        end

        _, first, = run_in(dir)
        after_first = scans
        _, second, = run_in(dir)

        expect(second).to eq(first)
        expect(after_first).to be_positive
        expect(scans).to eq(after_first)
        expect(File.exist?(File.join(dir, ".rigor/cache/reachability-scan.bundle"))).to be(true)
      end
    end

    it "re-scans an edited file and the report reflects the edit" do
      Dir.mktmpdir do |dir|
        write_project(dir)
        run_in(dir)

        File.write(File.join(dir, "lib/loner.rb"), "class Loner\nend\nclass Newcomer\nend\n")
        _, report, = run_in(dir)

        expect(report.fetch("candidates").map { |c| c.fetch("name") }).to include("Loner", "Newcomer")
      end
    end

    it "recovers from a corrupt bundle by recomputing everything" do
      Dir.mktmpdir do |dir|
        write_project(dir)
        _, first, = run_in(dir)

        File.write(File.join(dir, ".rigor/cache/reachability-scan.bundle"), "not a bundle")
        _, second, = run_in(dir)

        expect(second).to eq(first)
      end
    end
  end
end
