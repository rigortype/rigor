# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"

require "rigor/cli"

# `rigor init` fills `plugins:` from the project's Gemfile.lock through PluginGapAdvisory, the same read `rigor doctor`
# makes. Without a lockfile, or with `--no-plugins`, the written list stays empty.
RSpec.describe Rigor::CLI do
  let(:exe) { File.join(File.expand_path("../..", __dir__), "exe", "rigor") }

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  # The catalogue memoises process-wide; an earlier example's stubbed engine root would otherwise decide what is
  # detected here.
  before { Rigor::Plugin::BundledCatalog.reset! }

  # `rails` and `rspec-core` are the direct dependencies; `activerecord` and the other Rails family members are
  # reached through the `rails` umbrella, which is how the advisory expands it.
  def write_rails_rspec_lock
    File.write("Gemfile.lock", <<~LOCK)
      GEM
        remote: https://rubygems.org/
        specs:
          rails (8.0.1)
          rspec-core (3.13.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails
        rspec-core

      BUNDLED WITH
         2.6.2
    LOCK
  end

  def run_init(*flags)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(["init", "--path=.rigor.dist.yml", *flags], out: out, err: err).run
    [status, out.string, err.string]
  end

  def written_config
    YAML.safe_load_file(".rigor.dist.yml")
  end

  describe "with a Gemfile.lock that names rails and rspec-core" do
    before { write_rails_rspec_lock }

    it "writes the bundled plugins for those gems as active entries" do
      status, = run_init

      expect(status).to eq(0)
      expect(written_config["plugins"]).to include("rigor-activerecord", "rigor-railties", "rigor-rspec")
      expect(written_config["plugins"]).not_to include("rigor-sidekiq")
    end

    it "says in the template that the entries were detected from Gemfile.lock, above the list" do
      run_init

      expect(File.read(".rigor.dist.yml")).to include(
        "# Detected from Gemfile.lock by `rigor init`. Remove any you do not want.\nplugins:\n- rigor-"
      )
    end

    it "names the detected plugins in the next steps" do
      _status, out, = run_init

      expect(out).to include("review the plugins detected from Gemfile.lock (rigor-actioncable,")
      expect(out).to include("rigor-rspec).")
    end

    it "writes a config whose plugins list the loader accepts, the way `rigor plugins --strict` checks it" do
      run_init

      # A child process, as a user runs it: the strict gate exits 1 on any load error, and the spec loads the
      # same bundled set a CI gate would.
      _stdout, stderr, status = Open3.capture3(
        "bundle", "exec", "ruby", exe, "plugins", "--strict", "--config=.rigor.dist.yml", chdir: Dir.pwd,
                                                                                          stdin_data: ""
      )

      expect(status.exitstatus).to eq(0), stderr
    end

    it "still writes YAML that round-trips through Configuration.load" do
      run_init

      expect(Rigor::Configuration.load(".rigor.dist.yml").plugins).not_to be_empty
    end

    it "writes an empty plugins list under --no-plugins, with the original next steps" do
      status, out, = run_init("--no-plugins")

      expect(status).to eq(0)
      expect(written_config["plugins"]).to eq([])
      expect(File.read(".rigor.dist.yml")).not_to include("Detected from Gemfile.lock")
      expect(out).to include("1. Edit .rigor.dist.yml — add the `plugins:` your project needs.")
    end
  end

  it "writes the template unchanged when there is no Gemfile.lock" do
    status, out, = run_init

    expect(status).to eq(0)
    expect(File.read(".rigor.dist.yml")).to match(/^plugins: \[\]$/)
    expect(File.read(".rigor.dist.yml")).not_to include("Detected from Gemfile.lock")
    expect(out).to include("1. Edit .rigor.dist.yml — add the `plugins:` your project needs.")
  end

  it "writes no plugin entries when the lockfile names no gem a bundled plugin models" do
    File.write("Gemfile.lock", "GEM\n  specs:\n    some-gem (1.0.0)\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  some-gem\n")

    run_init

    expect(File.read(".rigor.dist.yml")).to match(/^plugins: \[\]$/)
  end
end
