# frozen_string_literal: true

require "rigor/language_server/uri"

RSpec.describe Rigor::LanguageServer::Uri do
  describe ".to_path" do
    it "decodes a simple file:// URI" do
      expect(described_class.to_path("file:///abs/path/lib/foo.rb")).to eq("/abs/path/lib/foo.rb")
    end

    it "percent-decodes RFC-3986 escapes (spaces, unicode)" do
      expect(described_class.to_path("file:///tmp/has%20space.rb")).to eq("/tmp/has space.rb")
      expect(described_class.to_path("file:///tmp/%E6%97%A5.rb")).to eq("/tmp/日.rb")
    end

    it "returns nil for non-file schemes" do
      expect(described_class.to_path("untitled:Untitled-1")).to be_nil
      expect(described_class.to_path("http://example.com/foo.rb")).to be_nil
    end

    it "returns nil for non-String input" do
      expect(described_class.to_path(nil)).to be_nil
      expect(described_class.to_path(42)).to be_nil
    end
  end

  describe ".from_path" do
    it "round-trips a simple path" do
      uri = described_class.from_path("/abs/foo.rb")
      expect(described_class.to_path(uri)).to eq("/abs/foo.rb")
    end
  end
end
