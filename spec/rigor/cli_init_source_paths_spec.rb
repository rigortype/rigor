# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "yaml"

require "rigor/cli"

# #2560 — `rigor init` writes the active `paths: [lib]` it always did. In a Rails application (config/application.rb)
# it also suggests app/ and lib/ as a commented `paths:` block, so a user who uncomments it scans app/ too. The active
# value never changes; the suggestion is not enabled (#2557's shape for plugins).
RSpec.describe Rigor::CLI do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def run_init(path = ".rigor.dist.yml")
    run_init_output(path)
  end

  def run_init_output(path = ".rigor.dist.yml")
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(["init", "--path=#{path}"], out: out, err: err).run
    expect(status).to eq(0), err.string
    out.string
  end

  def written_text(path = ".rigor.dist.yml")
    File.read(path)
  end

  def write_rails_application
    FileUtils.mkdir_p(%w[app lib config])
    FileUtils.touch("config/application.rb")
  end

  # What the user has after uncommenting the suggestion: the active list removed and the commented line made live.
  def uncommented_text(path = ".rigor.dist.yml")
    written_text(path).sub(/^paths:\n(?:- .*\n)+/, "").sub("# paths: ", "paths: ")
  end

  describe "in a Rails application with app/ and lib/" do
    before { write_rails_application }

    it "keeps the active paths: [lib] and writes the commented suggestion beneath it" do
      run_init

      expect(YAML.safe_load_file(".rigor.dist.yml")["paths"]).to eq(["lib"])
      expect(written_text).to include(
        "- lib\n# Detected a Rails app (config/application.rb): app, lib. To scan them, delete the `paths:` list " \
        "above and uncomment the line below:\n# paths: [app, lib]\nexclude: []\n"
      )
    end

    it "tells the user in Next steps that rigor check analyses only lib until they edit paths:" do
      expect(run_init_output).to include(
        "     `rigor check` analyses only `lib` until you edit `paths:` in .rigor.dist.yml. The suggestion is " \
        "commented beneath it.\n"
      )
    end

    it "loads app/ and lib/ once the user uncomments the suggestion" do
      run_init
      File.write("uncommented.yml", uncommented_text)

      expect(Rigor::Configuration.load("uncommented.yml").paths).to eq(
        [File.expand_path("app"), File.expand_path("lib")]
      )
    end

    it "writes the suggestion relative to a config file written elsewhere (#1399)" do
      FileUtils.mkdir_p("config")

      run_init("config/rigor.yml")

      expect(written_text("config/rigor.yml")).to include("# paths: [../app, ../lib]\n")
      expect(YAML.safe_load_file("config/rigor.yml")["paths"]).to eq(["../lib"])
    end
  end

  describe "in a Rails application with no lib/" do
    before do
      FileUtils.mkdir_p(%w[app config])
      FileUtils.touch("config/application.rb")
    end

    it "suggests app/ alone and keeps the active paths: [lib]" do
      run_init

      expect(YAML.safe_load_file(".rigor.dist.yml")["paths"]).to eq(["lib"])
      expect(written_text).to include("# paths: [app]\n")
    end

    it "says it, not them, when only app/ is suggested" do
      run_init

      expect(written_text).to include("To scan it, delete the `paths:` list above and uncomment the line below:\n")
      expect(written_text).not_to include("To scan them")
    end
  end

  describe "in a Rails application with neither app/ nor lib/" do
    before do
      FileUtils.mkdir_p("config")
      FileUtils.touch("config/application.rb")
    end

    it "writes no suggestion and no Next steps line" do
      output = run_init_output

      expect(written_text).not_to include("app, lib")
      expect(written_text).not_to include("# paths:")
      expect(written_text).not_to include("Detected a Rails app")
      expect(output).not_to include("analyses only `lib`")
    end
  end

  describe "in a Rails application where app is a regular file" do
    before do
      FileUtils.mkdir_p(%w[lib config])
      FileUtils.touch(%w[app config/application.rb])
    end

    it "writes no suggestion, since app/ is not a directory" do
      run_init

      expect(written_text).not_to include("Detected a Rails app")
      expect(written_text).not_to include("# paths:")
    end
  end

  describe "in a Rails application where config/application.rb is a directory" do
    before do
      FileUtils.mkdir_p(%w[app lib config/application.rb])
    end

    it "writes no suggestion, since the marker is not a file" do
      run_init

      expect(written_text).not_to include("Detected a Rails app")
      expect(written_text).not_to include("# paths:")
    end
  end

  describe "in a Rails application with only lib/" do
    before do
      FileUtils.mkdir_p(%w[lib config])
      FileUtils.touch("config/application.rb")
    end

    it "writes the unchanged template, since the detection is exactly [lib]" do
      run_init

      expect(written_text).not_to include("Detected a Rails app")
      expect(written_text).not_to include("# paths:")
    end
  end

  describe "in a gem layout with an app/ directory" do
    before do
      FileUtils.mkdir_p(%w[app lib])
      FileUtils.touch("example.gemspec")
    end

    it "writes the unchanged template with no paths: suggestion" do
      run_init

      expect(YAML.safe_load_file(".rigor.dist.yml")["paths"]).to eq(["lib"])
      expect(written_text).not_to include("Detected a Rails app")
      expect(written_text).not_to include("# paths:")
    end
  end

  describe "in an empty directory" do
    it "writes the unchanged template with no paths: suggestion and no Next steps line" do
      output = run_init_output

      expect(YAML.safe_load_file(".rigor.dist.yml")["paths"]).to eq(["lib"])
      expect(written_text).not_to include("Detected a Rails app")
      expect(written_text).not_to include("# paths:")
      expect(output).not_to include("analyses only `lib`")
    end
  end
end
