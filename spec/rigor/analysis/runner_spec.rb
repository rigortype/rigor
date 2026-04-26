# frozen_string_literal: true

require "tmpdir"
require "rigor/analysis/runner"

RSpec.describe Rigor::Analysis::Runner do
  it "reports Prism parse errors as diagnostics" do
    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "broken.rb")
      File.write(source_path, "def broken\n")

      configuration = Rigor::Configuration.new("paths" => [dir])
      result = described_class.new(configuration: configuration).run

      expect(result).not_to be_success
      expect(result.diagnostics.first.path).to eq(source_path)
      expect(result.diagnostics.first.message).not_to be_empty
    end
  end
end
