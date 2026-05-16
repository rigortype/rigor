# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"

RSpec.describe Rigor::LanguageServer::CompletionProvider do
  let(:buffer_table)  { Rigor::LanguageServer::BufferTable.new }
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:project_context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }
  let(:provider) do
    described_class.new(buffer_table: buffer_table, project_context: project_context)
  end

  let(:uri) { "file:///tmp/comp.rb" }

  describe "#provide" do
    it "returns nil for non-file URIs" do
      expect(provider.provide(uri: "untitled:foo", line: 0, character: 0)).to be_nil
    end

    it "returns nil when the buffer isn't open" do
      expect(provider.provide(uri: "file:///nope.rb", line: 0, character: 0)).to be_nil
    end

    it "returns nil when the buffer has parse errors AND no sentinel patch applies" do
      buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)
      expect(provider.provide(uri: uri, line: 0, character: 0)).to be_nil
    end

    it "returns method completions for `obj.method_name|` on a String receiver" do
      # Cursor on `upcase` should return String's methods.
      buffer_table.open(uri: uri, bytes: "\"hi\".upcase\n", version: 1)
      items = provider.provide(uri: uri, line: 0, character: 9)

      expect(items).not_to be_nil
      expect(items.first).to include(:label, :kind, :detail, :insertText)
      labels = items.map { |i| i[:label] }
      expect(labels).to include("upcase", "downcase", "length")
    end

    it "marks every CompletionItem with kind 2 (Method)" do
      buffer_table.open(uri: uri, bytes: "\"hi\".upcase\n", version: 1)
      items = provider.provide(uri: uri, line: 0, character: 9)

      kinds = items.map { |i| i[:kind] }.uniq
      expect(kinds).to eq([Rigor::LanguageServer::CompletionProvider::KIND_METHOD])
    end

    it "returns singleton-method completions for `Foo.|` (Type::Singleton receiver)" do
      buffer_table.open(uri: uri, bytes: "String.new\n", version: 1)
      items = provider.provide(uri: uri, line: 0, character: 9)

      expect(items).not_to be_nil
      labels = items.map { |i| i[:label] }
      # `new` is a singleton method on String (well, on Class —
      # inherited but still enumerated).
      expect(labels).to include("new")
    end

    it "filters out private methods on explicit receivers" do
      buffer_table.open(uri: uri, bytes: "\"hi\".upcase\n", version: 1)
      items = provider.provide(uri: uri, line: 0, character: 9)

      labels = items.map { |i| i[:label] }
      # `initialize` is private on String; should not appear.
      expect(labels).not_to include("initialize")
    end

    it "returns nil when the receiver type isn't a supported carrier" do
      # `foo` with no receiver — implicit self. Slice 5 doesn't
      # support implicit-self completion.
      buffer_table.open(uri: uri, bytes: "foo\n", version: 1)
      expect(provider.provide(uri: uri, line: 0, character: 2)).to be_nil
    end

    describe "composite-receiver handling (slice B3)" do
      it "enumerates Array's methods for a tuple-shape receiver" do
        # `[1, 2, 3]` infers to a Tuple carrier; method completion
        # should fall through to Array's instance methods.
        buffer_table.open(uri: uri, bytes: "[1, 2, 3].length\n", version: 1)
        items = provider.provide(uri: uri, line: 0, character: 11)

        expect(items).not_to be_nil
        labels = items.map { |i| i[:label] }
        expect(labels).to include("length", "size", "first")
      end

      it "enumerates Hash's methods for a hash-shape receiver" do
        buffer_table.open(uri: uri, bytes: "{a: 1, b: 2}.keys\n", version: 1)
        items = provider.provide(uri: uri, line: 0, character: 14)

        expect(items).not_to be_nil
        labels = items.map { |i| i[:label] }
        expect(labels).to include("keys", "values", "each_pair")
      end
    end

    describe "constant-path completion (slice B2)" do
      it "returns child constants for `Foo::Bar` when cursor is on `Bar`" do
        # `Process::Status` — Status is a known child of Process
        # in the bundled stdlib RBS. Cursor on `Status` should
        # surface every immediate child of `Process`.
        buffer_table.open(uri: uri, bytes: "Process::Status\n", version: 1)
        items = provider.provide(uri: uri, line: 0, character: 12)

        expect(items).not_to be_nil
        labels = items.map { |i| i[:label] }
        expect(labels).to include("Status")
      end

      it "marks constant-path items with kind 7 (Class)" do
        buffer_table.open(uri: uri, bytes: "Process::Status\n", version: 1)
        items = provider.provide(uri: uri, line: 0, character: 12)

        expect(items.map { |i| i[:kind] }.uniq).to eq([7])
      end

      it "filters out non-immediate descendants (no `::` in tail)" do
        buffer_table.open(uri: uri, bytes: "Process::Status\n", version: 1)
        items = provider.provide(uri: uri, line: 0, character: 12)

        labels = items.map { |i| i[:label] }
        # No label should contain `::` — only immediate children.
        expect(labels.none? { |l| l.include?("::") }).to be(true)
      end

      it "renders the full FQN in the detail field" do
        buffer_table.open(uri: uri, bytes: "Process::Status\n", version: 1)
        items = provider.provide(uri: uri, line: 0, character: 12)

        status = items.find { |i| i[:label] == "Status" }
        expect(status[:detail]).to eq("Process::Status")
      end
    end

    describe "hash-key completion (slice D1)" do
      it "returns the HashShape's keys for `hash[:|` mid-edit" do
        # Buffer: `h = {a: 1, b: 2, ccc: 3}; h[:` (incomplete).
        # The provider should patch `__rigor_lsp_key__]` and surface
        # the three keys from the HashShape carrier.
        source = "h = {a: 1, b: 2, ccc: 3}\nh[:\n"
        buffer_table.open(uri: uri, bytes: source, version: 1)
        items = provider.provide(uri: uri, line: 1, character: 3)

        expect(items).not_to be_nil
        labels = items.map { |i| i[:label] }
        expect(labels).to contain_exactly(":a", ":b", ":ccc")
      end

      it "marks hash-key items with kind 5 (Field)" do
        source = "h = {x: 1}\nh[:\n"
        buffer_table.open(uri: uri, bytes: source, version: 1)
        items = provider.provide(uri: uri, line: 1, character: 3)

        expect(items.first[:kind]).to eq(Rigor::LanguageServer::CompletionProvider::KIND_FIELD)
      end

      it "falls back to method completion when the receiver isn't a HashShape" do
        # `[1, 2].[:foo` — receiver is Tuple, not HashShape. The
        # provider should NOT return hash-key items; falls through
        # to method completion (Array methods).
        source = "[1, 2][:\n"
        buffer_table.open(uri: uri, bytes: source, version: 1)
        items = provider.provide(uri: uri, line: 0, character: 8)

        # Either nil or Array method completions — but NOT hash
        # keys. Hash-key items would have labels starting with `:`.
        if items
          labels = items.map { |i| i[:label] }
          expect(labels.none? { |l| l.start_with?(":") }).to be(true)
        end
      end
    end

    describe "parse-recovery sentinel (slice B4)" do
      it "completes after a trailing `.` even though the buffer doesn't parse" do
        # `"hi".` is malformed Ruby; provider should patch with
        # the method sentinel and return String's methods.
        buffer_table.open(uri: uri, bytes: "\"hi\".\n", version: 1)
        items = provider.provide(uri: uri, line: 0, character: 5)

        expect(items).not_to be_nil
        labels = items.map { |i| i[:label] }
        expect(labels).to include("upcase", "downcase")
      end

      it "completes after a trailing `::` even though the buffer doesn't parse" do
        buffer_table.open(uri: uri, bytes: "Process::\n", version: 1)
        items = provider.provide(uri: uri, line: 0, character: 9)

        expect(items).not_to be_nil
        labels = items.map { |i| i[:label] }
        expect(labels).to include("Status")
      end
    end
  end
end
