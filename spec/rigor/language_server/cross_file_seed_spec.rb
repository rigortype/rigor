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
  let(:uri) { "file://#{File.join(lib, 'main.rb')}" }

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

    it "reads the open buffer's declarations, not the file on disk" do
      m_path = File.join(lib, "m.rb")
      File.write(m_path, "class Gone\nend\nmodule M\n  def self.h = 1\n  Y = 1\nend\n")
      m_uri = "file://#{m_path}"
      # The buffer deleted every declaration the disk copy has, keeping only uses of them.
      buffer_table.open(uri: m_uri, bytes: "M.h\nM::Y\nGone\n", version: 1)

      hovers = [[0, 2], [1, 3], [2, 1]].map do |line, col|
        provider(described_class).provide(uri: m_uri, line: line, character: col)
      end

      expect(hovers.map { |hover| hover[:contents][:value][/Dynamic/] }).to eq(%w[Dynamic Dynamic Dynamic])
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
