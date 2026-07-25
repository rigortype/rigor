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
      # textDocumentSync: INCREMENTAL (openClose + change: 2), with the position encoding stated explicitly.
      expect(result[:capabilities][:textDocumentSync]).to eq(openClose: true, change: 2)
      expect(result[:capabilities][:positionEncoding]).to eq("utf-16")
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
      # Per LSP § "exit": clients that exit without shutdown signal an abnormal termination; the server SHOULD set a
      # non-zero exit code.
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

      # `Server.new` here has no hover_provider wired, so the dispatcher returns MethodNotFound even for
      # `textDocument/hover`.
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

    def range_change(from_line, from_char, to_line, to_char, text)
      {
        range: {
          start: { line: from_line, character: from_char },
          end: { line: to_line, character: to_char }
        },
        text: text
      }
    end

    it "didOpen populates the BufferTable" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x = 1\n" }
                      })

      expect(server.buffer_table[uri].bytes).to eq("x = 1\n")
      expect(server.buffer_table[uri].version).to eq(1)
    end

    it "didChange with no range replaces the whole buffer (still legal under incremental sync)" do
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

    it "didChange splices a range edit into the held buffer" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x = 1\ny = 2\n" }
                      })
      server.dispatch("textDocument/didChange", {
                        textDocument: { uri: uri, version: 2 },
                        contentChanges: [range_change(0, 4, 0, 5, "42")]
                      })

      expect(server.buffer_table[uri].bytes).to eq("x = 42\ny = 2\n")
      expect(server.buffer_table[uri].version).to eq(2)
    end

    it "didChange applies several range edits in order" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x\n" }
                      })
      server.dispatch("textDocument/didChange", {
                        textDocument: { uri: uri, version: 2 },
                        contentChanges: [range_change(0, 1, 0, 1, "yz"), range_change(0, 3, 0, 3, " = 1")]
                      })

      expect(server.buffer_table[uri].bytes).to eq("xyz = 1\n")
    end

    it "didChange counts a non-BMP character as two UTF-16 code units" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: %(a = "🍣"\n) }
                      })
      server.dispatch("textDocument/didChange", {
                        textDocument: { uri: uri, version: 2 },
                        contentChanges: [range_change(0, 8, 0, 8, ".freeze")]
                      })

      expect(server.buffer_table[uri].bytes).to eq(%(a = "🍣".freeze\n))
    end

    it "didChange with an unappliable range keeps the buffer and flags it desynchronised" do
      server.dispatch("textDocument/didOpen", {
                        textDocument: { uri: uri, languageId: "ruby", version: 1, text: "x = 1\n" }
                      })
      server.dispatch("textDocument/didChange", {
                        textDocument: { uri: uri, version: 2 },
                        contentChanges: [{ range: { start: { line: 0 }, end: { line: 0, character: 0 } }, text: "!" }]
                      })

      expect(server.buffer_table[uri].bytes).to eq("x = 1\n")
      expect(server.buffer_table.desynchronized?(uri)).to be(true)
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
        server.dispatch("initialize", {})
        # `initialize` already ran in before; dispatching again is an invalid-request, so re-construct.
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
