# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"

RSpec.describe Rigor::LanguageServer::HoverProvider do
  let(:buffer_table)  { Rigor::LanguageServer::BufferTable.new }
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:project_context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }
  let(:provider) do
    described_class.new(buffer_table: buffer_table, project_context: project_context)
  end

  let(:uri) { "file:///tmp/lsp-hover.rb" }

  describe "#provide" do
    it "returns nil for non-file URIs" do
      expect(provider.provide(uri: "untitled:Foo", line: 0, character: 0)).to be_nil
    end

    it "returns nil when the buffer isn't open" do
      expect(provider.provide(uri: "file:///nope.rb", line: 0, character: 0)).to be_nil
    end

    it "returns nil when the buffer has parse errors" do
      buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)
      expect(provider.provide(uri: uri, line: 0, character: 0)).to be_nil
    end

    it "returns a markdown Hover for a literal integer" do
      buffer_table.open(uri: uri, bytes: "42\n", version: 1)
      hover = provider.provide(uri: uri, line: 0, character: 0)

      expect(hover).not_to be_nil
      expect(hover[:contents][:kind]).to eq("markdown")
      # Slice A4 replaces the slice-A1 `type: / erased: / node:`
      # body with `# Type / # Erased` framing for literal nodes.
      expect(hover[:contents][:value]).to include("# Type")
      expect(hover[:contents][:value]).to include("42")
    end

    it "uses 0-based LSP line/character (no off-by-one against rigor's 1-based input)" do
      # `42` sits at LSP (0, 0). rigor's NodeLocator expects (1, 1).
      # HoverProvider must translate at the boundary; the literal
      # at that position should resolve and produce a non-nil hover.
      buffer_table.open(uri: uri, bytes: "42\n", version: 1)
      hover = provider.provide(uri: uri, line: 0, character: 0)

      expect(hover).not_to be_nil
      expect(hover[:contents][:value]).to include("42")
    end

    it "returns nil when the LSP position is out of range" do
      buffer_table.open(uri: uri, bytes: "42\n", version: 1)

      expect(provider.provide(uri: uri, line: 100, character: 100)).to be_nil
    end
  end
end
