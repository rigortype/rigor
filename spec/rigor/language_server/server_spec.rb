# frozen_string_literal: true

require "rigor/language_server"

RSpec.describe Rigor::LanguageServer::Server do
  let(:server) { described_class.new }

  describe "#dispatch — initialize → shutdown → exit happy path" do
    it "boots in :uninitialized and accepts `initialize`" do
      expect(server.state).to eq(:uninitialized)

      result = server.dispatch("initialize", { processId: 0, rootUri: nil, capabilities: {} })

      expect(server.state).to eq(:initialized)
      expect(result[:serverInfo]).to eq(name: "rigor-lsp", version: Rigor::VERSION)
      # Slice 3 advertises textDocumentSync (FULL).
      expect(result[:capabilities][:textDocumentSync]).to eq(openClose: true, change: 1)
    end

    it "accepts `shutdown` after `initialize` and transitions to :shutdown" do
      server.dispatch("initialize", {})
      result = server.dispatch("shutdown", nil)

      expect(server.state).to eq(:shutdown)
      expect(result).to be_nil
    end

    it "accepts `exit` after `shutdown` and sets exit_code = 0" do
      server.dispatch("initialize", {})
      server.dispatch("shutdown", nil)
      server.dispatch("exit", nil)

      expect(server).to be_exited
      expect(server.exit_code).to eq(0)
    end

    it "exits with code 1 if `exit` is called without a preceding `shutdown`" do
      # Per LSP § "exit": clients that exit without shutdown signal
      # an abnormal termination; the server SHOULD set a non-zero
      # exit code.
      server.dispatch("initialize", {})
      server.dispatch("exit", nil)

      expect(server.exit_code).to eq(1)
    end
  end

  describe "state-violation errors" do
    it "returns ServerNotInitialized (-32002) for non-initialize methods before initialize" do
      result = server.dispatch("textDocument/hover", {})

      expect(result.dig(:error, :code)).to eq(Rigor::LanguageServer::Server::ERROR_SERVER_NOT_INITIALIZED)
      expect(result.dig(:error, :message)).to include("textDocument/hover")
    end

    it "returns InvalidRequest if `initialize` is called twice" do
      server.dispatch("initialize", {})
      result = server.dispatch("initialize", {})

      expect(result.dig(:error, :code)).to eq(Rigor::LanguageServer::Server::ERROR_INVALID_REQUEST)
    end

    it "rejects every method except `exit` after shutdown" do
      server.dispatch("initialize", {})
      server.dispatch("shutdown", nil)
      result = server.dispatch("textDocument/hover", {})

      expect(result.dig(:error, :code)).to eq(Rigor::LanguageServer::Server::ERROR_INVALID_REQUEST_AFTER_SHUTDOWN)
    end
  end

  describe "MethodNotFound for advertised-but-unwired methods" do
    it "responds with MethodNotFound (-32601) for slice-1's unknown methods" do
      server.dispatch("initialize", {})
      result = server.dispatch("textDocument/hover", {})

      # Slice 1 advertises nothing in capabilities; hover lands in
      # slice 5. Until then the dispatcher returns MethodNotFound.
      expect(result.dig(:error, :code)).to eq(Rigor::LanguageServer::Server::ERROR_METHOD_NOT_FOUND)
    end
  end

  describe "`initialized` notification" do
    it "is accepted as a no-op (returns nil)" do
      server.dispatch("initialize", {})

      expect(server.dispatch("initialized", {})).to be_nil
      expect(server.state).to eq(:initialized)
    end
  end

  describe "textDocument sync (slice 3)" do
    let(:uri) { "file:///abs/path/lib/foo.rb" }

    before { server.dispatch("initialize", {}) }

    it "didOpen populates the BufferTable" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x = 1\n" }
                      })

      expect(server.buffer_table[uri].bytes).to eq("x = 1\n")
      expect(server.buffer_table[uri].version).to eq(1)
    end

    it "didChange replaces bytes under FULL sync" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "old\n" }
                      })
      server.dispatch("textDocument/didChange", {
                        textDocument: { uri: uri, version: 2 },
                        contentChanges: [{ text: "new\n" }]
                      })

      expect(server.buffer_table[uri].bytes).to eq("new\n")
      expect(server.buffer_table[uri].version).to eq(2)
    end

    it "didClose drops the entry from the BufferTable" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x" }
                      })
      server.dispatch("textDocument/didClose", { textDocument: { uri: uri } })

      expect(server.buffer_table[uri]).to be_nil
    end

    it "all three are notifications — dispatch returns nil" do
      open_result = server.dispatch("textDocument/didOpen", {
                                      textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x" }
                                    })
      change_result = server.dispatch("textDocument/didChange", {
                                        textDocument: { uri: uri, version: 2 },
                                        contentChanges: [{ text: "y" }]
                                      })
      close_result = server.dispatch("textDocument/didClose", { textDocument: { uri: uri } })

      expect([open_result, change_result, close_result]).to all(be_nil)
    end
  end

  describe "publisher integration (slice 4)" do
    let(:uri) { "file:///abs/path/lib/foo.rb" }
    let(:publisher) do
      Class.new do
        attr_reader :publish_calls, :empty_calls

        def initialize
          @publish_calls = []
          @empty_calls = []
        end

        def publish_for(uri)
          @publish_calls << uri
        end

        def publish_empty(uri)
          @empty_calls << uri
        end
      end.new
    end
    let(:server) { described_class.new(publisher: publisher) }

    before { server.dispatch("initialize", {}) }

    it "calls publish_for after didOpen" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x" }
                      })

      expect(publisher.publish_calls).to eq([uri])
    end

    it "calls publish_for after didChange" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x" }
                      })
      server.dispatch("textDocument/didChange", {
                        textDocument: { uri: uri, version: 2 },
                        contentChanges: [{ text: "y" }]
                      })

      expect(publisher.publish_calls).to eq([uri, uri])
    end

    it "calls publish_empty after didClose to clear inline markers" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x" }
                      })
      server.dispatch("textDocument/didClose", { textDocument: { uri: uri } })

      expect(publisher.empty_calls).to eq([uri])
    end
  end

  describe "hover provider integration (slice 5)" do
    let(:uri) { "file:///abs/path/foo.rb" }

    context "when no hover provider is wired" do
      let(:server) { described_class.new }

      before { server.dispatch("initialize", {}) }

      it "advertises no hoverProvider capability" do
        result = server.dispatch("initialize", {})
        # `initialize` already ran in before; dispatching again is
        # an invalid-request, so re-construct.
        s = described_class.new
        result = s.dispatch("initialize", {})
        expect(result[:capabilities]).not_to include(:hoverProvider)
      end

      it "returns MethodNotFound for textDocument/hover" do
        result = server.dispatch("textDocument/hover", {
                                   textDocument: { uri: uri },
                                   position: { line: 0, character: 0 }
                                 })

        expect(result.dig(:error, :code)).to eq(Rigor::LanguageServer::Server::ERROR_METHOD_NOT_FOUND)
      end
    end

    context "when a hover provider is wired" do
      let(:provider) do
        Class.new do
          def provide(uri:, line:, character:)
            { contents: { kind: "markdown", value: "<<#{uri}:#{line}:#{character}>>" } }
          end
        end.new
      end
      let(:server) { described_class.new(hover_provider: provider) }

      before { server.dispatch("initialize", {}) }

      it "advertises hoverProvider in capabilities" do
        s = described_class.new(hover_provider: provider)
        result = s.dispatch("initialize", {})
        expect(result[:capabilities][:hoverProvider]).to be(true)
      end

      it "routes textDocument/hover through the provider" do
        result = server.dispatch("textDocument/hover", {
                                   textDocument: { uri: uri },
                                   position: { line: 3, character: 7 }
                                 })

        expect(result[:contents][:value]).to eq("<<#{uri}:3:7>>")
      end
    end
  end

  describe "workspace/* invalidation (slice 7)" do
    let(:context) do
      Rigor::LanguageServer::ProjectContext.new(
        configuration: Rigor::Configuration.new("paths" => [])
      )
    end
    let(:server) { described_class.new(project_context: context) }

    before { server.dispatch("initialize", {}) }

    it "didChangeWatchedFiles bumps the project context generation" do
      expect do
        server.dispatch("workspace/didChangeWatchedFiles", { changes: [] })
      end.to change(context, :generation).by(1)
    end

    it "didChangeConfiguration bumps the project context generation" do
      expect do
        server.dispatch("workspace/didChangeConfiguration", { settings: {} })
      end.to change(context, :generation).by(1)
    end

    it "both are notifications — dispatch returns nil" do
      expect(server.dispatch("workspace/didChangeWatchedFiles", { changes: [] })).to be_nil
      expect(server.dispatch("workspace/didChangeConfiguration", { settings: {} })).to be_nil
    end
  end
end
