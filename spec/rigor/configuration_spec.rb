# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rigor::Configuration do
  describe ".load" do
    it "loads defaults when the configuration file is absent" do
      Dir.mktmpdir do |dir|
        configuration = described_class.load(File.join(dir, "missing.yml"))

        expect(configuration.target_ruby).to eq("4.0")
        expect(configuration.paths).to eq(["lib"])
        expect(configuration.plugins).to eq([])
        expect(configuration.cache_path).to eq(".rigor/cache")
      end
    end
  end
end
