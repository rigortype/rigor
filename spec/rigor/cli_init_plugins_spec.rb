# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"

require "rigor/cli"

# `rigor init` suggests the bundled plugins whose gems the project's Gemfile.lock declares, through PluginGapAdvisory
# (the read `rigor doctor` makes). They are written as comments under `plugins: []` (ADR-96 Criterion 2: a lockfile's
# presence does not opt a project into a plugin's code), so nothing loads until the user uncomments them.
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

  def written_text
    File.read(".rigor.dist.yml")
  end

  # The suggested gems, read back from the `#   - gem` lines the template writes.
  def suggested_gems
    written_text.scan(/^#   - (\S+)$/).flatten
  end

  # What the user has after doing the step the Next steps describe: `[]` deleted, `plugins:` and the entries
  # uncommented.
  def uncommented_text
    written_text.sub("plugins: []\n", "plugins:\n").gsub(/^#   - /, "  - ")
  end

  describe "with a Gemfile.lock that names rails and rspec-core" do
    before { write_rails_rspec_lock }

    it "suggests the bundled plugins for those gems as comments, leaving plugins: empty" do
      status, = run_init

      expect(status).to eq(0)
      expect(suggested_gems).to eq(
        %w[rigor-actioncable rigor-actionmailer rigor-actionpack rigor-activejob rigor-activerecord
           rigor-activestorage rigor-activesupport-core-ext rigor-rails-routes rigor-railties rigor-rspec]
      )
      expect(YAML.safe_load_file(".rigor.dist.yml")["plugins"]).to eq([])
      expect(Rigor::Configuration.load(".rigor.dist.yml").plugins).to be_empty
    end

    it "explains in the template that the suggestions are not enabled, above the list" do
      run_init

      expect(written_text).to include(
        "plugins: []\n# Detected from Gemfile.lock (suggested, not enabled). To load them, delete the `[]` above, " \
        "uncomment the\n# entries you want, then run `rigor plugins --strict`.\n#   - rigor-"
      )
    end

    it "lists each suggested plugin on its own line in the next steps" do
      _status, out, = run_init

      expect(out).to include("delete the `[]` on the `plugins:` line and")
      suggested_gems.each { |gem| expect(out).to include("\n       #{gem}\n") }
    end

    # The strict gate, run as a user runs it after uncommenting: the loader must accept every suggested plugin.
    it "loads the uncommented suggestions the way `rigor plugins --strict` checks them" do
      run_init
      File.write("uncommented.yml", uncommented_text)

      _stdout, stderr, status = Open3.capture3(
        "bundle", "exec", "ruby", exe, "plugins", "--strict", "--config=uncommented.yml",
        chdir: Dir.pwd, stdin_data: ""
      )

      expect(status.exitstatus).to eq(0), stderr
      expect(Rigor::Configuration.load("uncommented.yml").plugins).not_to be_empty
    end

    it "writes plugins: [] and no suggestions under --no-plugins, with the original next steps" do
      status, out, = run_init("--no-plugins")

      expect(status).to eq(0)
      expect(YAML.safe_load_file(".rigor.dist.yml")["plugins"]).to eq([])
      expect(written_text).not_to include("Detected from Gemfile.lock")
      expect(out).to include("1. Edit .rigor.dist.yml — add the `plugins:` your project needs.")
    end
  end

  it "writes the template unchanged when there is no Gemfile.lock" do
    status, out, = run_init

    expect(status).to eq(0)
    expect(written_text).to match(/^plugins: \[\]$/)
    expect(written_text).not_to include("Detected from Gemfile.lock")
    expect(out).to include("1. Edit .rigor.dist.yml — add the `plugins:` your project needs.")
  end

  it "writes no suggestions when the lockfile names no gem a bundled plugin models" do
    File.write("Gemfile.lock", "GEM\n  specs:\n    some-gem (1.0.0)\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  some-gem\n")

    run_init

    expect(written_text).to match(/^plugins: \[\]$/)
    expect(written_text).not_to include("Detected from Gemfile.lock")
  end
end
