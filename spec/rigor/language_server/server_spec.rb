# frozen_string_literal: true

require "rigor/language_server"

RSpec.describe Rigor::LanguageServer::Server do
  let(:server) { described_class.new }

  describe "#dispatch — initialize → shutdown → exit happy path" do
    it "boots in :uninitialized and accepts `initialize`" do
      expect(server.state).to eq(:uninitialized)

      result = server.dispatch("initialize", { processId: 0, rootUri: nil, capabilities: {} })

      expect(server.state).to eq(:initialized)
      expect(result).to include(
        capabilities: {},
        serverInfo: { name: "rigor-lsp", version: Rigor::VERSION }
      )
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
end
