# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rigor/language_server"
require "rigor/configuration"

# Issue #2282 — hover, completion and signature help probe with the same cross-file discovery seed the diagnostic
# publisher hands its `Runner`, so a constant or method another project file defines answers what `rigor check`
# would instead of `Dynamic`.
RSpec.describe "LSP editor queries over a project (#2282)" do
  let(:dir) { File.realpath(Dir.mktmpdir("rigor-lsp-query-seed-")) }
  let(:lib) { File.join(dir, "lib") }
  let(:buffer_table) { Rigor::LanguageServer::BufferTable.new }
  let(:project_context) do
    Rigor::LanguageServer::ProjectContext.new(configuration: Rigor::Configuration.new("paths" => paths))
  end
  let(:paths) { [lib] }
  let(:uri) { "file://#{File.join(lib, "main.rb")}" }

  before do
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "greeter.rb"), "class Greeter\n  LIMIT = 5\n  def self.make = \"hi\"\nend\n")
    File.write(File.join(lib, "main.rb"), "")
  end

  after { FileUtils.remove_entry(dir) }

  def open_buffer(bytes)
    buffer_table.open(uri: uri, bytes: bytes, version: 1)
  end

  def provider(klass)
    klass.new(buffer_table: buffer_table, project_context: project_context)
  end

  describe Rigor::LanguageServer::HoverProvider do
    it "shows a cross-file constant's type, not Dynamic" do
      open_buffer("Greeter::LIMIT\n")
      hover = provider(described_class).provide(uri: uri, line: 0, character: 10)

      expect(hover[:contents][:value]).to include("5")
      expect(hover[:contents][:value]).not_to include("Dynamic")
    end

    context "with no configured files (empty seed)" do
      let(:paths) { [] }

      it "keeps the single-file answer" do
        open_buffer("Greeter::LIMIT\n")
        hover = provider(described_class).provide(uri: uri, line: 0, character: 10)

        expect(hover[:contents][:value]).to include("Dynamic")
      end
    end
  end

  describe Rigor::LanguageServer::CompletionProvider do
    it "completes on the type a cross-file method returns" do
      open_buffer("Greeter.make.\n")
      items = provider(described_class).provide(uri: uri, line: 0, character: 13)

      expect(items.map { |item| item[:label] }).to include("upcase")
    end

    context "with no configured files (empty seed)" do
      let(:paths) { [] }

      it "does not offer it" do
        open_buffer("Greeter.make.\n")
        items = provider(described_class).provide(uri: uri, line: 0, character: 13)

        expect(Array(items).map { |item| item[:label] }).not_to include("upcase")
      end
    end
  end

  describe Rigor::LanguageServer::SignatureHelpProvider do
    it "resolves the signature on a cross-file method's return type" do
      open_buffer("Greeter.make.center(\n")
      result = provider(described_class).provide(uri: uri, line: 0, character: 20)

      expect(result[:signatures].first[:label]).to include("center")
    end

    context "with no configured files (empty seed)" do
      let(:paths) { [] }

      it "resolves nothing" do
        open_buffer("Greeter.make.center(\n")

        expect(provider(described_class).provide(uri: uri, line: 0, character: 20)).to be_nil
      end
    end
  end
end
