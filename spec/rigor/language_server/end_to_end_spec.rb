# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

# Spawns the real `exe/rigor lsp` binary and runs a full LSP
# session over stdin / stdout. Asserts that:
#
# - `initialize` returns the v1+v2 capability set.
# - `hover` returns a markdown body for a literal.
# - `completion` returns a method list for `obj.|`.
# - `shutdown` + `exit` terminates cleanly with exit code 0.
#
# `publishDiagnostics` is NOT asserted here. The notification
# fires through the 200ms Debouncer; by the time this batch-
# written session reaches `shutdown` (which calls
# `cancel_pending`), the debounced thread has been cancelled.
# That's the correct production behaviour — the publish path
# is covered by `diagnostic_publisher_spec`'s unit cases +
# `debouncer_spec`'s timing cases.
#
# This is the regression-guard spec the manual shell smoke scripts
# in commit messages cover. By running through `Open3.popen3` we
# exercise the same code path real LSP clients see — framed
# JSON-RPC over stdio, the gem's `Io::Reader/Writer`, the Loop's
# dispatch, every collaborator wired in `CLI::LspCommand#run`.
LSP_E2E_TIMEOUT_SECONDS = 30

RSpec.describe "rigor lsp end-to-end session", type: :integration do
  let(:binary) { File.expand_path("../../../exe/rigor", __dir__) }

  # rubocop:disable RSpec/ExampleLength
  it "round-trips a full initialize → didOpen → hover → completion → shutdown → exit session" do
    session_inputs = [
      request(1, "initialize", { capabilities: {} }),
      notification("textDocument/didOpen",
                   textDocument: {
                     uri: "file:///tmp/rigor_lsp_e2e.rb",
                     languageId: "ruby",
                     version: 1,
                     text: %("hi".upcase\n)
                   }),
      request(2, "textDocument/hover",
              textDocument: { uri: "file:///tmp/rigor_lsp_e2e.rb" },
              position: { line: 0, character: 6 }),
      request(3, "textDocument/completion",
              textDocument: { uri: "file:///tmp/rigor_lsp_e2e.rb" },
              position: { line: 0, character: 9 },
              context: { triggerKind: 2, triggerCharacter: "." }),
      request(4, "shutdown"),
      notification("exit")
    ]
    stdout_bytes, exit_status = run_session(session_inputs)
    frames = parse_frames(stdout_bytes)

    request_responses = frames.reject { |f| f[:method] == "textDocument/publishDiagnostics" }

    expect(exit_status).to eq(0)
    expect(request_responses.map { |f| f[:id] }).to eq([1, 2, 3, 4])

    # initialize — capabilities include textDocumentSync,
    # hoverProvider, completionProvider, documentSymbolProvider.
    init = request_responses.find { |f| f[:id] == 1 }
    caps = init.dig(:result, :capabilities)
    expect(caps).to include(:textDocumentSync, :hoverProvider,
                            :completionProvider, :documentSymbolProvider)

    # hover at the `upcase` position — CallNode renderer produces
    # the receiver / method / return body (LSP v2 slice A1).
    hover = request_responses.find { |f| f[:id] == 2 }
    expect(hover.dig(:result, :contents, :kind)).to eq("markdown")
    body = hover.dig(:result, :contents, :value)
    expect(body).to include("# Receiver", "String", "# Method", "String#upcase:")

    # completion — String's methods after `.upcase` cursor position.
    completion = request_responses.find { |f| f[:id] == 3 }
    labels = completion.fetch(:result).map { |item| item[:label] }
    expect(labels).to include("upcase", "downcase")

    # shutdown — returns null result per LSP spec.
    shutdown_response = request_responses.find { |f| f[:id] == 4 }
    expect(shutdown_response[:result]).to be_nil
  end
  # rubocop:enable RSpec/ExampleLength

  private

  def request(id, method, params = {})
    payload = { jsonrpc: "2.0", id: id, method: method }
    payload[:params] = params unless params.empty?
    payload
  end

  def notification(method, **params)
    payload = { jsonrpc: "2.0", method: method }
    payload[:params] = params unless params.empty?
    payload
  end

  def run_session(messages)
    framed = messages.map { |msg| frame(msg) }.join
    stdout_bytes = +""
    exit_status = nil

    Open3.popen3(binary, "lsp") do |stdin, stdout, _stderr, wait_thread|
      stdin.binmode
      stdout.binmode
      stdin.write(framed)
      stdin.close

      Timeout.timeout(LSP_E2E_TIMEOUT_SECONDS) do
        stdout_bytes << stdout.read
        exit_status = wait_thread.value.exitstatus
      end
    end

    [stdout_bytes, exit_status]
  end

  def frame(payload)
    body = JSON.generate(payload)
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def parse_frames(raw)
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
end
