# frozen_string_literal: true

# The partition CI uses to split the gated plugin integration run (`tool/plugin_integration_shard.rb`). A file in no
# shard is a plugin spec CI never runs, and the gate with it; a file in two shards only costs time.
require "tmpdir"
require "spec_helper"

require_relative "../../tool/plugin_integration_shard"

RSpec.describe PluginIntegrationShard do
  let(:root) { Dir.mktmpdir("plugin-shard") }

  before do
    { "plugins/a_plugin_spec.rb" => 900, "plugins/b_plugin_spec.rb" => 500, "plugins/c_plugin_spec.rb" => 400,
      "examples/d_plugin_spec.rb" => 300, "examples/e_plugin_spec.rb" => 100 }.each do |relative, bytes|
      path = File.join(root, "spec/integration", relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#" * bytes)
    end
  end

  after { FileUtils.rm_rf(root) }

  it "lists the plugin and example specs when no shard is named" do
    expect(described_class.shard(nil, root).map { |path| File.basename(path) })
      .to eq(%w[d_plugin_spec.rb e_plugin_spec.rb a_plugin_spec.rb b_plugin_spec.rb c_plugin_spec.rb])
  end

  it "puts every file in exactly one shard" do
    shards = (1..3).map { |index| described_class.shard("#{index}/3", root) }

    expect(shards.flatten.sort).to eq(described_class.all(root))
  end

  it "balances by size, largest file first onto the lightest shard" do
    sizes = (1..2).map do |index|
      described_class.shard("#{index}/2", root).sum { |path| File.size(File.join(root, path)) }
    end

    expect(sizes).to eq([1200, 1000])
  end

  it "rejects a shard outside 1..N" do
    expect { described_class.shard("4/3", root) }.to raise_error(ArgumentError, /1 <= I <= N/)
  end
end
