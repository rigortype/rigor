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

    it "returns nil when the buffer has parse errors (slice 8 handles recovery)" do
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
  end
end
