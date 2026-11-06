# frozen_string_literal: true

# Issue #2455 — a document nested deeply enough to overflow `Prism.parse` on a debouncer thread (C level, no backtrace)
# must not stop the server publishing diagnostics for every other document: the batcher drops that document and
# releases its round.
require "spec_helper"
require "json"
require "open3"
require "timeout"
require "tmpdir"

RSpec.describe "rigor lsp with a deeply nested document (#2455)", type: :integration do
  let(:binary) { File.expand_path("../../exe/rigor", __dir__) }

  def frame(message)
    body = JSON.generate(message)
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def open_doc(dir, name, text)
    frame(jsonrpc: "2.0", method: "textDocument/didOpen",
          params: { textDocument: { uri: "file://#{dir}/#{name}", languageId: "ruby", version: 1, text: text } })
  end

  # Reads frames from `stdout` until one satisfies the block; returns it, or nil at EOF.
  def read_until(stdout)
    buffer = +"".b
    loop do
      buffer << stdout.readpartial(65_536)
      while (match = buffer.match(/Content-Length: (\d+)\r\n\r\n/i)) && buffer.bytesize >= match.end(0) + match[1].to_i
        message = JSON.parse(buffer.byteslice(match.end(0), match[1].to_i), symbolize_names: true)
        buffer = buffer.byteslice((match.end(0) + match[1].to_i)..)
        return message if yield(message)
      end
    end
  rescue EOFError
    nil
  end

  it "still publishes another document's diagnostics, and exits 0" do
    Dir.mktmpdir("rigor-lsp-deep-") do |dir|
      File.write(File.join(dir, ".rigor.yml"), "paths:\n  - .\n")
      published = nil
      status = nil
      Open3.popen3(binary, "lsp", chdir: dir) do |stdin, stdout, _stderr, wait|
        stdin.binmode
        stdin.write(frame(jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} }))
        stdin.write(open_doc(dir, "deep.rb", "x = #{'[' * 1400}1#{']' * 1400}\n"))
        stdin.write(open_doc(dir, "ok.rb", "1.no_ctrl\n"))
        Timeout.timeout(60) do
          published = read_until(stdout) do |m|
            m[:method] == "textDocument/publishDiagnostics" && m.dig(:params, :uri).end_with?("ok.rb") &&
              !m.dig(:params, :diagnostics).empty?
          end
        end
        stdin.write(frame(jsonrpc: "2.0", id: 2, method: "shutdown"))
        stdin.write(frame(jsonrpc: "2.0", method: "exit"))
        stdin.close
        status = wait.value.exitstatus
      end
      expect(published).not_to be_nil
      expect(status).to eq(0)
    end
  end
end
