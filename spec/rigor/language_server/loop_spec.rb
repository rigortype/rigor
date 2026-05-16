# frozen_string_literal: true

require "json"
require "rigor/language_server"
require "language_server-protocol"

RSpec.describe Rigor::LanguageServer::Loop do
  # Wraps one full `initialize → shutdown → exit` round-trip
  # through the Loop, using IO.pipe pairs for the client → server
  # and server → client streams. Returns the parsed server-side
  # responses in order.
  def run_loop(messages)
    server_in_r, server_in_w = IO.pipe   # client writes here; server reads.
    server_out_r, server_out_w = IO.pipe # server writes here; client reads.

    messages.each { |msg| write_frame(server_in_w, msg) }
    server_in_w.close

    server = Rigor::LanguageServer::Server.new
    described_class.new(
      reader: ::LanguageServer::Protocol::Transport::Io::Reader.new(server_in_r),
      writer: ::LanguageServer::Protocol::Transport::Io::Writer.new(server_out_w),
      server: server
    ).run
    server_out_w.close

    [server, read_frames(server_out_r)]
  end

  def write_frame(io, payload)
    body = JSON.generate(payload)
    io.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  end

  def read_frames(io)
    raw = io.read
    frames = []
    offset = 0
    while (match = raw.byteslice(offset..).match(/Content-Length: (\d+)\r\n\r\n/i))
      length = match[1].to_i
      header_end = offset + match.end(0)
      frames << JSON.parse(raw.byteslice(header_end, length), symbolize_names: true)
      offset = header_end + length
    end
    frames
  end

  describe "happy path — initialize → shutdown → exit" do
    let(:result) do
      run_loop([
                 { jsonrpc: "2.0", id: 1, method: "initialize", params: { processId: 0, capabilities: {} } },
                 { jsonrpc: "2.0", id: 2, method: "shutdown" },
                 { jsonrpc: "2.0", method: "exit" }
               ])
    end

    it "returns the initialize response with the advertised capabilities + serverInfo" do
      _server, frames = result

      expect(frames[0]).to include(jsonrpc: "2.0", id: 1)
      expect(frames[0][:result]).to include(
        capabilities: {},
        serverInfo: hash_including(name: "rigor-lsp")
      )
    end

    it "returns null result for the shutdown request" do
      _server, frames = result

      expect(frames[1]).to include(jsonrpc: "2.0", id: 2, result: nil)
    end

    it "writes no response for the `exit` notification" do
      _server, frames = result

      # Two frames total: initialize + shutdown. exit is a notification.
      expect(frames.size).to eq(2)
    end

    it "exits cleanly with exit_code = 0 after the round-trip" do
      server, _ = result

      expect(server).to be_exited
      expect(server.exit_code).to eq(0)
    end
  end

  describe "error envelope" do
    it "returns ServerNotInitialized for non-lifecycle requests before initialize" do
      _server, frames = run_loop([
                                   { jsonrpc: "2.0", id: 1, method: "textDocument/hover", params: {} },
                                   { jsonrpc: "2.0", method: "exit" }
                                 ])

      expect(frames[0]).to include(id: 1)
      expect(frames[0][:error]).to include(
        code: Rigor::LanguageServer::Server::ERROR_SERVER_NOT_INITIALIZED
      )
    end
  end

  describe "notification vs request distinction" do
    it "writes no response for a notification without an `id`" do
      _server, frames = run_loop([
                                   { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
                                   { jsonrpc: "2.0", method: "initialized", params: {} },
                                   { jsonrpc: "2.0", id: 2, method: "shutdown" },
                                   { jsonrpc: "2.0", method: "exit" }
                                 ])

      # Three inbound: initialize (request), initialized (notif),
      # shutdown (request), exit (notif). Two responses expected.
      expect(frames.size).to eq(2)
      expect(frames.map { |f| f[:id] }).to eq([1, 2])
    end
  end
end
