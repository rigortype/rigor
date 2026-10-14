# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"

require "rigor/cli"

# #1388 — `rigor init` spells out `test_paths:` as the test roots it finds, so a new project's config says where its
# tests are instead of leaving it to auto-detection.
RSpec.describe Rigor::CLI do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def init_config(path = ".rigor.dist.yml")
    status = described_class.new(["init", "--path=#{path}"], out: StringIO.new, err: StringIO.new).run
    expect(status).to eq(0)
    YAML.safe_load_file(path)
  end

  it "writes the spec/ and test/ directories it finds" do
    FileUtils.mkdir_p(%w[spec test])

    config = init_config

    expect(config["test_paths"]).to eq(%w[spec test])
    loaded = Rigor::Configuration.load(".rigor.dist.yml").test_paths
    expect(loaded).to eq(%w[spec test].map { |root| File.expand_path(root) })
  end

  it "writes the roots relative to a config file written elsewhere, so they load back to the same directories" do
    FileUtils.mkdir_p(%w[spec config])

    config = init_config("config/rigor.yml")

    expect(config["test_paths"]).to eq(["../spec"])
    expect(Rigor::Configuration.load("config/rigor.yml").test_paths).to eq([File.expand_path("spec")])
  end

  # #1399 — `paths:` is cwd-relative in the default settings, so it is rewritten against the config file's directory
  # the same way `test_paths:` is. Without this, `config/rigor.yml` says `paths: [lib]` and loads back as `config/lib`.
  it "writes paths: relative to a config file written elsewhere, so it loads back to the project's lib/" do
    FileUtils.mkdir_p(%w[lib config])

    config = init_config("config/rigor.yml")

    expect(config["paths"]).to eq(["../lib"])
    expect(Rigor::Configuration.load("config/rigor.yml").paths).to eq([File.expand_path("lib")])
  end

  it "keeps paths: [lib] for the default config at the project root" do
    FileUtils.mkdir_p("lib")

    config = init_config

    expect(config["paths"]).to eq(["lib"])
  end

  it "leaves test_paths: unset (auto-detect) when there is no test directory yet" do
    config = init_config

    expect(config).to have_key("test_paths")
    expect(config["test_paths"]).to be_nil
  end
end
