# frozen_string_literal: true

require "rigor/language_server/buffer_table"

RSpec.describe Rigor::LanguageServer::BufferTable do
  let(:table) { described_class.new }
  let(:uri)   { "file:///abs/path/lib/foo.rb" }

  describe "#open" do
    it "stores an Entry under the URI" do
      table.open(uri: uri, bytes: "x = 1\n", version: 1)

      entry = table[uri]
      expect(entry.uri).to eq(uri)
      expect(entry.bytes).to eq("x = 1\n")
      expect(entry.version).to eq(1)
    end

    it "replaces an existing entry for the same URI (re-open)" do
      table.open(uri: uri, bytes: "old\n", version: 1)
      table.open(uri: uri, bytes: "new\n", version: 2)

      expect(table[uri].bytes).to eq("new\n")
      expect(table[uri].version).to eq(2)
    end
  end

  describe "#change (FULL sync)" do
    it "replaces the entry's bytes with the full new text" do
      table.open(uri: uri, bytes: "old\n", version: 1)
      table.change(uri: uri, bytes: "newer\n", version: 2)

      expect(table[uri].bytes).to eq("newer\n")
      expect(table[uri].version).to eq(2)
    end

    it "creates an entry even when no didOpen preceded it (defensive)" do
      table.change(uri: uri, bytes: "spawned\n", version: 5)

      expect(table.open?(uri)).to be(true)
      expect(table[uri].bytes).to eq("spawned\n")
    end
  end

  describe "#close" do
    it "removes the entry" do
      table.open(uri: uri, bytes: "x", version: 1)
      table.close(uri: uri)

      expect(table[uri]).to be_nil
      expect(table.open?(uri)).to be(false)
    end

    it "is a no-op for an unknown URI" do
      expect { table.close(uri: "file:///nope") }.not_to raise_error
    end
  end

  describe "#uris / #size" do
    it "reports the open URI set" do
      table.open(uri: "file:///a", bytes: "a", version: 1)
      table.open(uri: "file:///b", bytes: "b", version: 1)

      expect(table.uris).to contain_exactly("file:///a", "file:///b")
      expect(table.size).to eq(2)
    end
  end
end
