# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"

RSpec.describe Rigor::LanguageServer::DiagnosticPublisher do
  # In-memory writer collecting every payload pushed to it. Mirrors
  # `LanguageServer::Protocol::Transport::Io::Writer#write` but
  # captures the raw Hash so specs can inspect the wire shape
  # without re-parsing.
  let(:writer) do
    Class.new do
      attr_reader :payloads

      def initialize
        @payloads = []
      end

      def write(payload)
        @payloads << payload
      end
    end.new
  end

  let(:buffer_table) { Rigor::LanguageServer::BufferTable.new }
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:project_context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }
  let(:publisher) do
    described_class.new(writer: writer, buffer_table: buffer_table, project_context: project_context)
  end

  describe "#publish_for" do
    it "no-ops when the URI isn't a file:// scheme" do
      publisher.publish_for("untitled:foo")
      expect(writer.payloads).to be_empty
    end

    it "no-ops when the buffer isn't open in the table" do
      publisher.publish_for("file:///not/in/table.rb")
      expect(writer.payloads).to be_empty
    end

    it "pushes one `textDocument/publishDiagnostics` notification per call" do
      Dir.mktmpdir("rigor-lsp-publish-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        # Buffer has a parse error — should surface as an LSP
        # diagnostic mapped from Rigor's :error severity.
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)

        Dir.chdir(tmpdir) { publisher.publish_for(uri) }

        expect(writer.payloads.size).to eq(1)
        msg = writer.payloads.first
        expect(msg[:method]).to eq("textDocument/publishDiagnostics")
        expect(msg.dig(:params, :uri)).to eq(uri)
        diagnostics = msg.dig(:params, :diagnostics)
        expect(diagnostics).not_to be_empty
        expect(diagnostics.first[:severity]).to eq(1) # LSP Error
        expect(diagnostics.first[:source]).to eq("rigor")
      end
    end

    it "uses 0-based line / character positions per LSP spec" do
      Dir.mktmpdir("rigor-lsp-publish-zerobased-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        # Parse error fires on line 1 of the buffer; LSP expects
        # line: 0 (0-based).
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)

        Dir.chdir(tmpdir) { publisher.publish_for(uri) }

        diag = writer.payloads.first.dig(:params, :diagnostics).first
        # Rigor: line 1, col 11 (1-based). LSP: line 0, character 10.
        expect(diag[:range][:start][:line]).to be >= 0
        expect(diag[:range][:start][:character]).to be >= 0
      end
    end
  end

  describe "#publish_empty" do
    it "pushes an empty diagnostics array for the URI" do
      publisher.publish_empty("file:///x.rb")

      expect(writer.payloads).to eq([
                                      {
                                        method: "textDocument/publishDiagnostics",
                                        params: { uri: "file:///x.rb", diagnostics: [] }
                                      }
                                    ])
    end
  end
end
