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

  # Issue #882 — ADR-102 WD6's ownership test is "does something OUTSIDE the project already declare this
  # name?", and the environment answering it was built from `libraries:` alone. A gem whose signatures reach
  # the project through an installed `rbs collection` (or the bundle's per-gem `sig/`) was therefore invisible
  # to the test, so reopening one of its classes registered a project declaration nothing references — the
  # exact artifact WD6 exists to suppress, on a report whose adjudicated precision is 7.0%.
  describe "ownership against the project's dependency sources" do
    def install_collection(dir, gem_name, version, rbs)
      gem_dir = File.join(dir, ".gem_rbs_collection", gem_name, version)
      FileUtils.mkdir_p(gem_dir)
      File.write(File.join(gem_dir, "#{gem_name}.rbs"), rbs)
      File.write(File.join(dir, "rbs_collection.lock.yaml"), <<~YAML)
        ---
        path: ".gem_rbs_collection"
        gems:
        - name: #{gem_name}
          version: '#{version}'
          source:
            type: git
            name: ruby/gem_rbs_collection
            remote: https://github.com/ruby/gem_rbs_collection.git
            revision: abc
            repo_dir: gems
        gemfile_lock_path: Gemfile.lock
      YAML
    end

    it "keeps a class the rbs collection declares out of the candidate list" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, ".rigor.yml"), <<~YAML)
          paths:
            - lib
          rbs_collection:
            lockfile: rbs_collection.lock.yaml
            auto_detect: false
        YAML
        install_collection(dir, "legacybase", "1.0", "class LegacyBase\nend\n")
        File.write(File.join(dir, "lib/legacy_base.rb"), "class LegacyBase\n  def helper = 1\nend\n")
        # The discrimination control: same shape, same absence of references, declared by nobody but the
        # project. It must still be reported, or the example would pass on an environment that knows
        # everything just as happily as on one that knows the collection.
        File.write(File.join(dir, "lib/loner.rb"), "class Loner\nend\n")
        backdate(dir)

        status, report, = run_in(dir)

        expect(status).to eq(0)
        names = report.fetch("candidates").map { |c| c.fetch("name") }
        expect(names).to include("Loner")
        expect(names).not_to include("LegacyBase")
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

  # ADR-102 WD5 — the refusal is the soundness boundary made visible, and the ADR requires a spec to
  # pin it: the failure mode of silently absorbing `--incremental` is a confidently-wrong candidate
  # list, which no later run reports as an error.
  describe "`--incremental` (ADR-102 WD5)" do
    def run_raw(dir, *argv)
      out = StringIO.new
      err = StringIO.new
      status = Dir.chdir(dir) { described_class.new(argv: argv, out: out, err: err).run }
      [status, out.string, err.string]
    end

    it "refuses `--incremental` with a non-zero exit and an explanatory message" do
      Dir.mktmpdir do |dir|
        write_project(dir)
        status, out, err = run_raw(dir, "--incremental")

        expect(status).to eq(Rigor::CLI::EXIT_USAGE)
        expect(status).not_to eq(0)
        expect(err).to include("does not support --incremental")
        expect(err).to include("whole-project")
        expect(out).to be_empty
      end
    end

    it "refuses it wherever it appears in the argument list" do
      Dir.mktmpdir do |dir|
        write_project(dir)
        status, _out, err = run_raw(dir, "--format=json", "--incremental", "lib")

        expect(status).to eq(Rigor::CLI::EXIT_USAGE)
        expect(err).to include("does not support --incremental")
      end
    end

    # The control: the refusal must be specific to the rejected flag, not a broken option parser.
    it "still runs a whole-project report when the flag is absent" do
      Dir.mktmpdir do |dir|
        write_project(dir)
        status, payload, err = run_in(dir)

        expect(status).to eq(0)
        expect(err).not_to include("--incremental")
        expect(payload).to have_key("candidates")
      end
    end
  end
end
