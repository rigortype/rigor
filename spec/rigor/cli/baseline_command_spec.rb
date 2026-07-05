# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "yaml"

require "rigor/cli"
require "rigor/cli/baseline_command"

RSpec.describe Rigor::CLI::BaselineCommand do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def run_cli(*argv, cwd: nil)
    out = StringIO.new
    err = StringIO.new
    status = if cwd
               Dir.chdir(cwd) { Rigor::CLI.start(argv, out: out, err: err) }
             else
               Rigor::CLI.start(argv, out: out, err: err)
             end
    [status, out.string, err.string]
  end

  def write_demo_project(diagnostic_source: "x = 1\nputs x\n")
    FileUtils.mkdir_p(File.join(tmpdir, "lib"))
    File.write(File.join(tmpdir, "lib", "demo.rb"), diagnostic_source)
    File.write(File.join(tmpdir, ".rigor.yml"), <<~YAML)
      paths:
        - lib
      libraries:
        - prism
    YAML
  end

  describe "help / usage" do
    it "lists `generate` under the baseline help" do
      status, out, _err = run_cli("baseline", "help")
      expect(status).to eq(0)
      expect(out).to include("generate")
    end

    it "exits with the usage code on an unknown subcommand" do
      status, _out, err = run_cli("baseline", "unknown")
      expect(status).to eq(described_class::EXIT_USAGE)
      expect(err).to include("Unknown baseline subcommand")
    end
  end

  describe "generate" do
    before { write_demo_project }

    it "writes the baseline file at the default path with `version: 1`" do
      status, _out, err = run_cli("baseline", "generate", cwd: tmpdir)
      expect(status).to eq(0)
      baseline_path = File.join(tmpdir, ".rigor-baseline.yml")
      expect(File.exist?(baseline_path)).to be(true)
      data = YAML.safe_load_file(baseline_path)
      expect(data["version"]).to eq(1)
      expect(data["ignored"]).to be_an(Array)
      expect(err).to include("wrote baseline")
    end

    it "warns when the config does not declare `baseline:`" do
      _status, _out, err = run_cli("baseline", "generate", cwd: tmpdir)
      expect(err).to include("note — `.rigor.yml` does not declare `baseline:`")
    end

    it "refuses to overwrite an existing baseline without --force" do
      File.write(File.join(tmpdir, ".rigor-baseline.yml"), "version: 1\nignored: []\n")
      status, _out, err = run_cli("baseline", "generate", cwd: tmpdir)
      expect(status).to eq(described_class::EXIT_USAGE)
      expect(err).to include("already exists")
    end

    it "overwrites with --force" do
      File.write(File.join(tmpdir, ".rigor-baseline.yml"), "stale: content\n")
      status, _out, _err = run_cli("baseline", "generate", "--force", cwd: tmpdir)
      expect(status).to eq(0)
      data = YAML.safe_load_file(File.join(tmpdir, ".rigor-baseline.yml"))
      expect(data["version"]).to eq(1)
    end

    it "honours --output=PATH" do
      status, _out, _err = run_cli(
        "baseline", "generate", "--output=custom-baseline.yml", cwd: tmpdir
      )
      expect(status).to eq(0)
      expect(File.exist?(File.join(tmpdir, "custom-baseline.yml"))).to be(true)
    end
  end

  describe "rigor check --baseline" do
    let(:diagnostic_source) do
      # Deliberate undefined-method on a well-typed receiver (Integer) so rigor fires `call.undefined-method` reliably.
      # Two sites so the baseline gets a non-empty bucket.
      <<~RUBY
        1.this_method_does_not_exist
        2.also_not_a_method
      RUBY
    end

    before { write_demo_project(diagnostic_source: diagnostic_source) }

    it "silences baselined diagnostics when --baseline=PATH is supplied" do
      _status, _out, _err = run_cli("baseline", "generate", cwd: tmpdir)
      baseline_path = File.join(tmpdir, ".rigor-baseline.yml")

      _status, out, err = run_cli("check", "--baseline=#{baseline_path}", cwd: tmpdir)
      expect(err).to include("silenced by baseline")
      expect(out).not_to include("this_method_does_not_exist")
      expect(out).not_to include("also_not_a_method")
    end

    it "ignores any configured baseline when --no-baseline is passed" do
      _status, _out, _err = run_cli("baseline", "generate", cwd: tmpdir)
      File.write(File.join(tmpdir, ".rigor.yml"), <<~YAML)
        paths:
          - lib
        libraries:
          - prism
        baseline: .rigor-baseline.yml
      YAML

      _status, out, _err = run_cli("check", "--no-baseline", cwd: tmpdir)
      expect(out).to include("this_method_does_not_exist")
    end

    it "honours the `baseline: PATH` config key when no CLI flag is supplied" do
      _status, _out, _err = run_cli("baseline", "generate", cwd: tmpdir)
      File.write(File.join(tmpdir, ".rigor.yml"), <<~YAML)
        paths:
          - lib
        libraries:
          - prism
        baseline: .rigor-baseline.yml
      YAML

      _status, out, err = run_cli("check", cwd: tmpdir)
      expect(err).to include("silenced by baseline")
      expect(out).not_to include("this_method_does_not_exist")
    end
  end

  describe "regenerate" do
    before { write_demo_project }

    it "rewrites an existing baseline unconditionally (no --force needed)" do
      File.write(File.join(tmpdir, ".rigor-baseline.yml"), "stale: content\n")
      status, _out, err = run_cli("baseline", "regenerate", cwd: tmpdir)
      expect(status).to eq(0)
      expect(err).to include("regenerated baseline")
      data = YAML.safe_load_file(File.join(tmpdir, ".rigor-baseline.yml"))
      expect(data["version"]).to eq(1)
      expect(data["ignored"]).to be_an(Array)
    end

    it "writes a fresh baseline when none exists yet" do
      status, _out, _err = run_cli("baseline", "regenerate", cwd: tmpdir)
      expect(status).to eq(0)
      expect(File.exist?(File.join(tmpdir, ".rigor-baseline.yml"))).to be(true)
    end
  end

  describe "rigor check --baseline-strict" do
    let(:diagnostic_source) do
      <<~RUBY
        1.this_method_does_not_exist
        2.also_not_a_method
      RUBY
    end

    before { write_demo_project(diagnostic_source: diagnostic_source) }

    it "passes when the current run matches the baseline exactly" do
      run_cli("baseline", "generate", cwd: tmpdir)
      status, _out, err = run_cli(
        "check", "--baseline=.rigor-baseline.yml", "--baseline-strict", cwd: tmpdir
      )
      expect(status).to eq(0)
      expect(err).not_to include("drifted")
    end

    it "fails on deficit drift even though the run has no surfaced diagnostics" do
      run_cli("baseline", "generate", cwd: tmpdir)
      # Clean the file: actual count drops below the baseline.
      File.write(File.join(tmpdir, "lib", "demo.rb"), "x = 1\n")
      status, _out, err = run_cli(
        "check", "--baseline=.rigor-baseline.yml", "--baseline-strict", cwd: tmpdir
      )
      expect(status).to eq(1)
      expect(err).to include("drifted")
      expect(err).to include("rigor baseline regenerate")
    end

    it "is a no-op with a note when no baseline is active" do
      File.write(File.join(tmpdir, "lib", "demo.rb"), "x = 1\n")
      status, _out, err = run_cli("check", "--baseline-strict", cwd: tmpdir)
      expect(status).to eq(0)
      expect(err).to include("no baseline is active")
    end
  end

  describe "dump" do
    let(:baseline_path) { File.join(tmpdir, ".rigor-baseline.yml") }

    before do
      File.write(baseline_path, <<~YAML)
        version: 1
        ignored:
          - file: app/models/user.rb
            rule: call.undefined-method
            count: 3
          - file: app/models/post.rb
            rule: call.undefined-method
            count: 1
          - file: app/services/foo.rb
            rule: nullable-receiver
            count: 2
      YAML
    end

    it "prints the baseline grouped by rule" do
      status, out, _err = run_cli("baseline", "dump", "--baseline=#{baseline_path}", cwd: tmpdir)
      expect(status).to eq(0)
      expect(out).to include("call.undefined-method")
      expect(out).to include("nullable-receiver")
      expect(out).to include("app/models/user.rb: 3")
      expect(out).to include("Total: 3 bucket(s)")
    end

    it "filters by --rule" do
      status, out, _err = run_cli("baseline", "dump", "--baseline=#{baseline_path}",
                                  "--rule=nullable-receiver", cwd: tmpdir)
      expect(status).to eq(0)
      expect(out).to include("nullable-receiver")
      expect(out).not_to include("call.undefined-method")
    end

    it "filters by --file glob" do
      status, out, _err = run_cli("baseline", "dump", "--baseline=#{baseline_path}",
                                  "--file=app/models/*", cwd: tmpdir)
      expect(status).to eq(0)
      expect(out).to include("app/models/user.rb")
      expect(out).to include("app/models/post.rb")
      expect(out).not_to include("app/services/foo.rb")
    end

    it "emits JSON when --format=json" do
      status, out, _err = run_cli("baseline", "dump", "--baseline=#{baseline_path}",
                                  "--format=json", cwd: tmpdir)
      expect(status).to eq(0)
      data = JSON.parse(out)
      expect(data["version"]).to eq(1)
      expect(data["ignored"].size).to eq(3)
    end

    it "exits with usage code when the baseline file is missing" do
      status, _out, err = run_cli("baseline", "dump", "--baseline=/nonexistent.yml", cwd: tmpdir)
      expect(status).to eq(described_class::EXIT_USAGE)
      expect(err).to include("baseline file not found")
    end
  end

  describe "drift / prune" do
    let(:diagnostic_source) do
      <<~RUBY
        1.this_method_does_not_exist
        2.also_not_a_method
      RUBY
    end

    before { write_demo_project(diagnostic_source: diagnostic_source) }

    it "drift reports no drift when the current run matches baseline exactly" do
      run_cli("baseline", "generate", cwd: tmpdir)
      status, out, _err = run_cli("baseline", "drift", cwd: tmpdir)
      expect(status).to eq(0)
      expect(out).to include("No drift detected")
    end

    it "drift reports :cleared when the baseline points at a now-clean file" do
      run_cli("baseline", "generate", cwd: tmpdir)
      # Remove the diagnostic source so actual count drops to zero.
      File.write(File.join(tmpdir, "lib", "demo.rb"), "x = 1\n")
      status, out, _err = run_cli("baseline", "drift", cwd: tmpdir)
      expect(status).to eq(0)
      expect(out).to include("Cleared")
    end

    it "drift reports :over when the codebase introduced new diagnostics" do
      run_cli("baseline", "generate", cwd: tmpdir)
      # Add a third site so actual count crosses threshold.
      File.write(File.join(tmpdir, "lib", "demo.rb"), <<~RUBY)
        1.this_method_does_not_exist
        2.also_not_a_method
        3.third_missing_method
      RUBY
      status, out, _err = run_cli("baseline", "drift", cwd: tmpdir)
      expect(status).to eq(0)
      expect(out).to include("Over threshold")
    end

    it "prune drops cleared buckets and reports the count" do
      run_cli("baseline", "generate", cwd: tmpdir)
      File.write(File.join(tmpdir, "lib", "demo.rb"), "x = 1\n")
      before_size = YAML.safe_load_file(File.join(tmpdir, ".rigor-baseline.yml"))["ignored"].size

      status, _out, err = run_cli("baseline", "prune", cwd: tmpdir)
      expect(status).to eq(0)
      expect(err).to include("pruned")
      after_size = YAML.safe_load_file(File.join(tmpdir, ".rigor-baseline.yml"))["ignored"].size
      expect(after_size).to be < before_size
    end

    it "prune --dry-run shows the candidates without writing the file" do
      run_cli("baseline", "generate", cwd: tmpdir)
      File.write(File.join(tmpdir, "lib", "demo.rb"), "x = 1\n")
      original = File.read(File.join(tmpdir, ".rigor-baseline.yml"))

      status, out, _err = run_cli("baseline", "prune", "--dry-run", cwd: tmpdir)
      expect(status).to eq(0)
      expect(out).to include("to prune")
      expect(File.read(File.join(tmpdir, ".rigor-baseline.yml"))).to eq(original)
    end

    it "prune exits cleanly with no candidates when the baseline still matches" do
      run_cli("baseline", "generate", cwd: tmpdir)
      status, out, _err = run_cli("baseline", "prune", cwd: tmpdir)
      expect(status).to eq(0)
      expect(out).to include("No cleared buckets")
    end
  end
end
