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

  describe "#change (full-text replacement)" do
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

  describe "#apply_changes (INCREMENTAL sync)" do
    def edit(from_line, from_char, to_line, to_char, text)
      {
        range: {
          start: { line: from_line, character: from_char },
          end: { line: to_line, character: to_char }
        },
        text: text
      }
    end

    it "splices a range edit into the held text and bumps the version" do
      table.open(uri: uri, bytes: "x = 1\n", version: 1)
      applied = table.apply_changes(uri: uri, changes: [edit(0, 4, 0, 5, "42")], version: 2)

      expect(applied).to be(true)
      expect(table[uri].bytes).to eq("x = 42\n")
      expect(table[uri].version).to eq(2)
      expect(table.desynchronized?(uri)).to be(false)
    end

    it "applies several changes in order, each against the previous result" do
      table.open(uri: uri, bytes: "x\n", version: 1)
      table.apply_changes(uri: uri, changes: [edit(0, 1, 0, 1, "yz"), edit(0, 3, 0, 3, " = 1")], version: 2)

      expect(table[uri].bytes).to eq("xyz = 1\n")
    end

    it "keeps UTF-16 offsets straight after a non-BMP character" do
      table.open(uri: uri, bytes: %(a = "🍣"\n), version: 1)
      table.apply_changes(uri: uri, changes: [edit(0, 8, 0, 8, ".freeze")], version: 2)

      expect(table[uri].bytes).to eq(%(a = "🍣".freeze\n))
    end

    it "accepts a no-range entry as the full new document text" do
      table.open(uri: uri, bytes: "old\n", version: 1)
      table.apply_changes(uri: uri, changes: [{ text: "new\n" }], version: 2)

      expect(table[uri].bytes).to eq("new\n")
    end

    it "creates the entry from a no-range change even when no didOpen preceded it (defensive)" do
      table.apply_changes(uri: uri, changes: [{ text: "spawned\n" }], version: 5)

      expect(table[uri].bytes).to eq("spawned\n")
    end
  end

  describe "#apply_changes — resync fallback" do
    let(:bad_change) { { range: { start: { line: 0 }, end: { line: 0, character: 0 } }, text: "x" } }

    it "keeps the last known-good text and marks the URI desynchronised" do
      table.open(uri: uri, bytes: "x = 1\n", version: 1)
      applied = table.apply_changes(uri: uri, changes: [bad_change], version: 2)

      expect(applied).to be(false)
      expect(table[uri].bytes).to eq("x = 1\n")
      expect(table[uri].version).to eq(1)
      expect(table.desynchronized?(uri)).to be(true)
      expect(table.desynchronization_reason(uri)).to include("non-negative Integer")
    end

    it "marks a range edit for a URI with no held buffer desynchronised rather than inventing one" do
      applied = table.apply_changes(
        uri: uri,
        changes: [{ range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } }, text: "x" }],
        version: 1
      )

      expect(applied).to be(false)
      expect(table.open?(uri)).to be(false)
      expect(table.desynchronized?(uri)).to be(true)
    end

    it "leaves the earlier changes of a failing batch unapplied — the batch is all-or-nothing" do
      table.open(uri: uri, bytes: "x = 1\n", version: 1)
      good = { range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } }, text: "y" }
      table.apply_changes(uri: uri, changes: [good, bad_change], version: 2)

      expect(table[uri].bytes).to eq("x = 1\n")
    end

    it "clears the mark on a full-text change" do
      table.open(uri: uri, bytes: "x = 1\n", version: 1)
      table.apply_changes(uri: uri, changes: [bad_change], version: 2)
      table.apply_changes(uri: uri, changes: [{ text: "resynced\n" }], version: 3)

      expect(table.desynchronized?(uri)).to be(false)
      expect(table[uri].bytes).to eq("resynced\n")
    end

    it "clears the mark on a re-open" do
      table.open(uri: uri, bytes: "x = 1\n", version: 1)
      table.apply_changes(uri: uri, changes: [bad_change], version: 2)
      table.open(uri: uri, bytes: "reopened\n", version: 3)

      expect(table.desynchronized?(uri)).to be(false)
    end

    it "clears the mark on close" do
      table.open(uri: uri, bytes: "x = 1\n", version: 1)
      table.apply_changes(uri: uri, changes: [bad_change], version: 2)
      table.close(uri: uri)

      expect(table.desynchronized?(uri)).to be(false)
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

  # #246 — dirtiness is the protocol's notion ("changed and not yet saved"), not a byte comparison with disk.
  # The publish set excludes a dirty buffer, so this flag is what keeps a save round from replacing a dirty
  # buffer's correct markers with markers computed from the file on disk.
  describe "#dirty? / #save" do
    it "is clean on open, dirty after a change, clean again after a save" do
      table.open(uri: "file:///a", bytes: "a", version: 1)
      expect(table.dirty?("file:///a")).to be(false)

      table.change(uri: "file:///a", bytes: "b", version: 2)
      expect(table.dirty?("file:///a")).to be(true)

      table.save(uri: "file:///a")
      expect(table.dirty?("file:///a")).to be(false)
    end

    it "marks dirty on an incremental change too, applied or not" do
      table.open(uri: "file:///a", bytes: "abc", version: 1)
      table.apply_changes(
        uri: "file:///a", version: 2,
        changes: [{ range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } }, text: "z" }]
      )
      expect(table.dirty?("file:///a")).to be(true)
    end

    it "re-opening resets dirtiness — the payload carries the client's full text" do
      table.open(uri: "file:///a", bytes: "a", version: 1)
      table.change(uri: "file:///a", bytes: "b", version: 2)
      table.open(uri: "file:///a", bytes: "c", version: 3)

      expect(table.dirty?("file:///a")).to be(false)
    end

    it "forgets dirtiness when the buffer closes" do
      table.open(uri: "file:///a", bytes: "a", version: 1)
      table.change(uri: "file:///a", bytes: "b", version: 2)
      table.close(uri: "file:///a")

      expect(table.dirty?("file:///a")).to be(false)
    end
  end
end
