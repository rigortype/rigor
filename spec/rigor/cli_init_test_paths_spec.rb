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

  it "leaves test_paths: unset (auto-detect) when there is no test directory yet" do
    config = init_config

    expect(config).to have_key("test_paths")
    expect(config["test_paths"]).to be_nil
  end
end
