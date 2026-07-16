# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/doctor_command"

RSpec.describe Rigor::CLI::DoctorCommand do
  def run(argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: argv.dup, out: out, err: err).run
    [status, out.string, err.string]
  end

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  it "is a Command subclass" do
    expect(described_class.superclass).to eq(Rigor::CLI::Command)
  end

  describe "with no configuration" do
    it "reports a config issue because no config file exists" do
      # When no config exists, Configuration.load(nil) uses defaults. The default paths may not exist, but the runner
      # handles that. We just assert the command completes without crashing.
      status, out, = run([])
      expect(status).to be_a(Integer)
      expect(out).to include("rigor doctor:")
    end
  end

  describe "with a clean configuration" do
    it "reports all checks passed in text mode" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\n")

      status, out, err = run([])
      expect(status).to eq(0)
      expect(out).to include("all checks passed")
      expect(out).to include("rbs_environment")
      expect(err).to be_empty
    end

    # A quarantined `.rbs` keeps the env NON-empty (that is the point of quarantining it), so the class count
    # alone reads as healthy — doctor used to say exactly that while the project's own types were silently gone.
    it "reports a degraded RBS environment when a signature file was quarantined" do
      # The loader's stderr banner is a separate channel from this command's injected `out`/`err` (Kernel#warn
      # writes to the real $stderr, which `run` never captures); it is not what this example is about.
      allow_any_instance_of(Rigor::Environment::RbsLoader).to receive(:warn) # rubocop:disable RSpec/AnyInstance
      File.write("clean.rb", "x = 1\n")
      FileUtils.mkdir_p("sig")
      File.write(File.join("sig", "broken.rbs"),
                 "module Acme\n  class Broken\n    def h: () -> { data-contrast: Integer }\n  end\nend\n")
      File.write(".rigor.yml", "paths:\n  - clean.rb\nsignature_paths:\n  - sig\n")

      _status, out, = run([])
      expect(out).to include("[WARN] rbs_environment")
      expect(out).to include("RBS environment degraded")
      expect(out).to include("reject-unparseable-signatures")
      expect(out).not_to include("all checks passed")
      # A warn-only run must not headline "0 issue(s) found" above the finding it is reporting.
      expect(out).to include("1 warning(s) found")
    end

    it "reports clean JSON" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\n")

      status, out, err = run(["--format=json"])
      expect(status).to eq(0)
      payload = JSON.parse(out)
      expect(payload["status"]).to eq("clean")
      expect(payload["checks"]).to be_an(Array)
      expect(err).to be_empty
    end
  end

  describe "config audit" do
    it "fails when a signature_paths entry resolves to nothing" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\nsignature_paths:\n  - ./no_such_sig\n")

      status, out, = run([])
      expect(status).to eq(1)
      expect(out).to include("config_audit")
      expect(out).to include("FAIL")

      _status, json_out, = run(["--format=json"])
      payload = JSON.parse(json_out)
      config_check = payload["checks"].find { |c| c["id"] == "config_audit" }
      expect(config_check["status"]).to eq("fail")
      expect(config_check["hint"]).to include("Review and fix")
    end
  end

  describe "baseline check" do
    it "warns when the baseline file exists but is malformed" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\nbaseline: .rigor-baseline.yml\n")
      File.write(".rigor-baseline.yml", "not_valid_yaml: [\n")

      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("baseline")
      expect(out).to include("WARN")
      expect(out).to include("load failed")
    end

    it "passes when the baseline is present and clean" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\nbaseline: .rigor-baseline.yml\n")
      File.write(".rigor-baseline.yml", "version: 1\nignored: []\n")

      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("all checks passed")
    end

    it "fails with a drift summary when a recorded bucket no longer fires" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\nbaseline: .rigor-baseline.yml\n")
      # The bucket records one expected call.undefined-method on clean.rb, but the file is clean now → actual 0 → a
      # :cleared drift row.
      File.write(".rigor-baseline.yml", <<~YAML)
        version: 1
        ignored:
          - file: clean.rb
            rule: call.undefined-method
            count: 1
      YAML

      status, out, = run([])
      expect(status).to eq(1)
      expect(out).to include("Baseline drift detected")
      expect(out).to include("cleared")
    end
  end

  describe "plugin check" do
    it "passes when no plugins are configured" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\n")

      status, out, = run([])
      expect(status).to eq(0)
      expect(out).to include("all checks passed")
    end
  end

  describe "Rails plugin check" do
    it "fails when Gemfile.lock has railties but config has no Rails plugin" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\n")
      File.write("Gemfile.lock", "GEM\n  specs:\n    railties (8.0.0)\n")

      status, out, = run([])
      expect(status).to eq(1)
      expect(out).to include("rails_plugins")
      expect(out).to include("FAIL")
      expect(out).to include("Rails detected but no Rails plugins enabled")
    end

    it "does not flag rails_plugins when a Rails plugin is enabled" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\nplugins:\n  - rigor-activerecord\n")
      File.write("Gemfile.lock", "GEM\n  specs:\n    railties (8.0.0)\n")

      _status, out, = run([])
      expect(out).not_to include("rails_plugins")
    end
  end

  # ADR-27 — Rigor resolved as one of the project's own dependencies. The gem's own guardrails fire at install
  # and at boot; a project that already made the mistake never sees them again, so doctor names the state.
  describe "Gemfile install check" do
    def write_project(lock)
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\n")
      File.write("Gemfile.lock", lock)
    end

    it "fails when `rigortype` resolves from a GEM remote" do
      write_project(<<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            prism (1.9.0)
            rigortype (0.2.9)
              prism (>= 1.0, < 2.0)

        DEPENDENCIES
          rigortype
      LOCK

      status, out, = run([])
      expect(status).to eq(1)
      expect(out).to include("gemfile_install")
      expect(out).to include("FAIL")
      expect(out).to include("resolved as a dependency of this project")
      expect(out).to include("docs/install.md")
    end

    # The check that keeps this from firing on Rigor's own repo and every fork of it: the `gemspec` directive puts
    # `rigortype` in the lock under PATH. Matching the gem name alone would fail `rigor doctor` on Rigor itself.
    it "stays silent when `rigortype` comes from a PATH source" do
      write_project(<<~LOCK)
        PATH
          remote: .
          specs:
            rigortype (0.2.9)

        DEPENDENCIES
          rigortype!
      LOCK

      _status, out, = run([])
      expect(out).not_to include("gemfile_install")
    end

    it "stays silent when `rigortype` is vendored from git" do
      write_project(<<~LOCK)
        GIT
          remote: https://github.com/rigortype/rigor.git
          revision: 0000000000000000000000000000000000000000
          specs:
            rigortype (0.2.9)
      LOCK

      _status, out, = run([])
      expect(out).not_to include("gemfile_install")
    end

    # A six-space line is another gem's *dependency*, not a resolution, and CHECKSUMS names every gem in the
    # lock regardless of source. Neither means the project depends on Rigor.
    it "stays silent for a nested dependency line and a CHECKSUMS entry" do
      write_project(<<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            some-wrapper (1.0.0)
              rigortype (>= 0.2)

        CHECKSUMS
          rigortype (0.2.9) sha256=0000
      LOCK

      _status, out, = run([])
      expect(out).not_to include("gemfile_install")
    end

    it "stays silent when there is no Gemfile.lock at all" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\n")

      _status, out, = run([])
      expect(out).not_to include("gemfile_install")
    end
  end

  describe "help / usage" do
    it "is listed in `rigor help`" do
      out = StringIO.new
      Rigor::CLI.start(["help"], out: out, err: StringIO.new)
      expect(out.string).to include("doctor")
    end
  end

  describe "invalid format" do
    it "exits with usage error for an unsupported format" do
      File.write("clean.rb", "x = 1\n")
      File.write(".rigor.yml", "paths:\n  - .\n")

      status, _out, err = run(["--format=xml"])
      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to include("unsupported format: xml")
    end
  end

  # The private summary formatter behind the "Baseline drift detected (...)" message. Exercised directly with fabricated
  # audit rows (each answers #status) so the by-status counting, per-status labels, and joining are pinned without
  # staging a real drifting baseline.
  describe "#baseline_drift_summary (private)" do
    let(:command) { described_class.new(argv: [], out: StringIO.new, err: StringIO.new) }

    def drift_row(status) = Struct.new(:status).new(status)

    it "counts by status and joins the present labels" do
      rows = [drift_row(:over), drift_row(:over), drift_row(:cleared), drift_row(:reducible)]
      expect(command.send(:baseline_drift_summary, rows))
        .to eq("2 over threshold, 1 cleared, 1 reducible")
    end

    it "omits statuses that are absent from the drift set" do
      expect(command.send(:baseline_drift_summary, [drift_row(:over)])).to eq("1 over threshold")
    end
  end
end
