# frozen_string_literal: true

require "rigor/analysis/buffer_binding"

RSpec.describe Rigor::Analysis::BufferBinding do
  let(:binding) { described_class.new(logical_path: "lib/foo.rb", physical_path: "/tmp/buffer.rb") }

  describe "#resolve" do
    it "swaps the logical path for the physical path" do
      expect(binding.resolve("lib/foo.rb")).to eq("/tmp/buffer.rb")
    end

    it "passes through non-logical paths unchanged" do
      expect(binding.resolve("lib/bar.rb")).to eq("lib/bar.rb")
    end
  end

  describe "#display_path" do
    it "swaps the physical path for the logical path" do
      expect(binding.display_path("/tmp/buffer.rb")).to eq("lib/foo.rb")
    end

    it "passes through non-physical paths unchanged" do
      expect(binding.display_path("lib/bar.rb")).to eq("lib/bar.rb")
    end
  end

  it "is Ractor-shareable so it crosses pool boundaries safely" do
    expect(Ractor.shareable?(binding)).to be(true)
  end
end
