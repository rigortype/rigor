# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "tmpdir"

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

  # rubocop:disable-next RSpec/ExampleLength
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
    # Run in a throwaway directory: with the repo as the working directory the first
    # hover analyses the whole project, which is slow enough to time out under CI load.
    stdout_bytes, exit_status = Dir.mktmpdir("rigor-lsp-e2e-") { |dir| run_session(session_inputs, chdir: dir) }
    frames = parse_frames(stdout_bytes)

    request_responses = frames.reject { |f| f[:method] == "textDocument/publishDiagnostics" }

    expect(exit_status).to eq(0)
    expect(request_responses.map { |f| f[:id] }).to eq([1, 2, 3, 4])

    # initialize — capabilities include textDocumentSync, hoverProvider, completionProvider, documentSymbolProvider.
    init = request_responses.find { |f| f[:id] == 1 }
    caps = init.dig(:result, :capabilities)
    expect(caps).to include(:textDocumentSync, :hoverProvider,
                            :completionProvider, :documentSymbolProvider)

    # hover at the `upcase` position — CallNode renderer produces the # Receiver / # Method / # Return body.
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

  # `--log=PATH` appends every message, both directions, to PATH and leaves stdout as the protocol channel.
  it "appends each message in both directions to the --log file and keeps stdout unchanged" do
    Dir.mktmpdir("rigor-lsp-log-") do |dir|
      path = File.join(dir, "wire.log")
      stdout_bytes, exit_status = run_session(lifecycle_session, args: ["--log=#{path}"], chdir: dir)

      expect(exit_status).to eq(0)
      expect(parse_frames(stdout_bytes).map { |f| f[:id] }).to eq([1, 2])

      lines = File.readlines(path, chomp: true)
      expect(lines).to all(match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}[+-]\d\d:\d\d (<-|->) \{/))
      inbound = lines.grep(/ <- /).map { |line| JSON.parse(line.split(" <- ", 2).last) }
      outbound = lines.grep(/ -> /).map { |line| JSON.parse(line.split(" -> ", 2).last) }
      expect(inbound.map { |m| m["method"] || "response" }).to eq(%w[initialize shutdown exit])
      expect(outbound.map { |m| m["id"] }).to eq([1, 2])
      expect(lines.grep(/ -> /)).to all(include('"jsonrpc":"2.0"'))
      expect(outbound.first.dig("result", "capabilities")).to include("hoverProvider")
    end
  end

  # Raw invalid UTF-8 inside a didOpen string: the session still answers, and the log keeps a line for the message.
  it "keeps serving a didOpen holding invalid UTF-8 under --log, and logs it" do
    Dir.mktmpdir("rigor-lsp-log-") do |dir|
      path = File.join(dir, "wire.log")
      bad_text = "x = \\\"".b + "\xFF\xFE".b + "\\\"\\nputs x\\n".b
      bad_open = '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":' \
                 '{"uri":"file:///tmp/rigor_lsp_bad_utf8.rb","languageId":"ruby","version":1,"text":"'.b +
                 bad_text + '"}}}'.b
      session = [request(1, "initialize", { capabilities: {} }), bad_open,
                 request(2, "shutdown"), notification("exit")]

      stdout_bytes, exit_status = run_session(session, args: ["--log=#{path}"], chdir: dir)

      expect(exit_status).to eq(0)
      expect(parse_frames(stdout_bytes).filter_map { |f| f[:id] }).to eq([1, 2])
      line = File.readlines(path, chomp: true).find { |l| l.include?(" <- ") && l.include?("textDocument/didOpen") }
      expect(line).not_to be_nil
      expect(JSON.parse(line.split(" <- ", 2).last)["method"]).to eq("textDocument/didOpen")
    end
  end

  # Without `--log`, no wire log is written anywhere: the session's working directory stays empty.
  it "writes no log file and leaves stdout unchanged when --log is not given" do
    Dir.mktmpdir("rigor-lsp-cwd-") do |dir|
      stdout_bytes, exit_status, stderr_bytes = run_session(lifecycle_session, chdir: dir)

      expect(exit_status).to eq(0)
      expect(stderr_bytes).not_to match(/ (<-|->) \{/)
      expect(parse_frames(stdout_bytes).map { |f| f[:id] }).to eq([1, 2])
      expect(Dir.children(dir)).to be_empty
    end
  end

  private

  def lifecycle_session
    [
      request(1, "initialize", { capabilities: {} }),
      request(2, "shutdown"),
      notification("exit")
    ]
  end

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

  def run_session(messages, args: [], chdir: Dir.pwd)
    framed = messages.map { |msg| frame(msg) }.join
    stdout_bytes = +"".b
    stderr_bytes = +"".b
    exit_status = nil

    Open3.popen3(binary, "lsp", *args, chdir: chdir) do |stdin, stdout, stderr, wait_thread|
      stdin.binmode
      stdout.binmode
      stdin.write(framed)
      stdin.close

      begin
        Timeout.timeout(LSP_E2E_TIMEOUT_SECONDS) do
          # Read incrementally so the bytes already received survive a timeout.
          loop { stdout_bytes << stdout.readpartial(65_536) }
        rescue EOFError
          stderr_bytes << stderr.read
          exit_status = wait_thread.value.exitstatus
        end
      rescue Timeout::Error
        # Kill the child so popen3's join returns and the failure is reported, not hung.
        begin
          Process.kill("KILL", wait_thread.pid)
        rescue Errno::ESRCH
          nil
        end
        raise Timeout::Error, "rigor lsp did not exit within #{LSP_E2E_TIMEOUT_SECONDS}s " \
                              "(slow or hung); response ids read so far: " \
                              "#{response_ids_read(stdout_bytes).inspect}"
      end
    end

    [stdout_bytes, exit_status, stderr_bytes]
  end

  # Ids of the responses in a possibly truncated stream; tolerates a partial trailing frame.
  def response_ids_read(raw)
    ids = []
    offset = 0
    while (match = raw.byteslice(offset..).match(/Content-Length: (\d+)\r\n\r\n/i))
      length = match[1].to_i
      header_end = offset + match.end(0)
      break if header_end + length > raw.bytesize

      frame = JSON.parse(raw.byteslice(header_end, length), symbolize_names: true)
      ids << frame[:id] unless frame.key?(:method)
      offset = header_end + length
    end
    ids
  end

  def frame(payload)
    body = (payload.is_a?(String) ? payload : JSON.generate(payload)).b
    "Content-Length: #{body.bytesize}\r\n\r\n".b + body
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
