# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "rigor/cli"
require "rigor/cli/lsp_command"
require "rigor/configuration"
require "rigor/language_server"
require "language_server-protocol"

RSpec.describe Rigor::CLI::LspCommand do
  let(:wire_log_class) { Rigor::CLI::LspCommand::WireLog }

  # #1613 — a save round re-reads `.rigor.yml` through the loader the command wires in.
  it "wires a configuration_loader that re-loads the configuration at the given path" do
    command = described_class.new(argv: [], out: StringIO.new, err: StringIO.new)
    allow(Rigor::Configuration).to receive(:load).and_call_original

    server, = command.send(:build_server, writer: StringIO.new,
                                          reader: LanguageServer::Protocol::Transport::Io::Reader.new(StringIO.new),
                                          config_path: "tmp-missing.yml")
    context = server.instance_variable_get(:@project_context)
    loader = context.instance_variable_get(:@configuration_loader)

    expect(loader).to be_a(Proc)
    loader.call
    expect(Rigor::Configuration).to have_received(:load).with("tmp-missing.yml").twice
  end

  # --log=PATH that cannot be opened is a usage error reported before any server starts.
  it "exits with a usage error and a stderr message when --log cannot be opened" do
    err = StringIO.new
    command = described_class.new(argv: ["--log=/nonexistent-rigor-dir/wire.log"], out: StringIO.new, err: err)
    allow(command).to receive(:serve)

    expect(command.run).to eq(Rigor::CLI::EXIT_USAGE)
    expect(command).not_to have_received(:serve)
    expect(err.string).to include("cannot open --log file")
  end

  # The server's debug output (`warn`) goes to the wire log for the session, and $stderr is restored after it.
  it "routes the server's debug output into the --log file for the session" do
    Dir.mktmpdir("rigor-lsp-log-") do |dir|
      path = File.join(dir, "wire.log")
      command = described_class.new(argv: [], out: StringIO.new, err: StringIO.new)
      log = command.send(:open_wire_log, path)
      original_stderr = $stderr
      loop_runner = instance_double(Rigor::LanguageServer::Loop)
      allow(loop_runner).to receive(:run) { warn "debug marker" }
      server = instance_double(Rigor::LanguageServer::Server, exit_code: 0)
      allow(command).to receive(:build_server).and_return([server, loop_runner])
      allow(LanguageServer::Protocol::Transport::Io::Reader).to receive(:new).and_return(StringIO.new)
      allow(LanguageServer::Protocol::Transport::Io::Writer).to receive(:new).and_return(StringIO.new)

      expect(command.send(:serve, config_path: nil, log: log)).to eq(0)
      expect($stderr).to be(original_stderr)
      log.close
      expect(File.read(path)).to include("debug marker")
    end
  end

  # An exception escaping the loop is written to the log, and `$stderr` is still restored.
  it "restores $stderr and writes the exception to the log when the loop raises" do
    Dir.mktmpdir("rigor-lsp-log-") do |dir|
      path = File.join(dir, "wire.log")
      command = described_class.new(argv: [], out: StringIO.new, err: StringIO.new)
      log = command.send(:open_wire_log, path)
      original_stderr = $stderr
      loop_runner = instance_double(Rigor::LanguageServer::Loop)
      allow(loop_runner).to receive(:run) { raise "loop boom" }
      server = instance_double(Rigor::LanguageServer::Server, exit_code: 0)
      allow(command).to receive(:build_server).and_return([server, loop_runner])
      allow(LanguageServer::Protocol::Transport::Io::Reader).to receive(:new).and_return(StringIO.new)
      allow(LanguageServer::Protocol::Transport::Io::Writer).to receive(:new).and_return(StringIO.new)

      expect { command.send(:serve, config_path: nil, log: log) }.to raise_error(RuntimeError, "loop boom")
      expect($stderr).to be(original_stderr)
      log.close
      expect(File.read(path)).to include("RuntimeError: loop boom")
    end
  end

  # The wire log is synchronous: a logged line is on disk before the file is closed.
  it "writes each wire-log line through to the file without waiting for close" do
    Dir.mktmpdir("rigor-lsp-log-") do |dir|
      path = File.join(dir, "wire.log")
      command = described_class.new(argv: [], out: StringIO.new, err: StringIO.new)
      log = command.send(:open_wire_log, path)

      log.record("->", { id: 1, result: nil })

      expect(File.read(path)).to match(/ -> \{"id":1,"result":null\}\n\z/)
      log.close
    end
  end

  # A message the JSON encoder rejects is still logged, as a scrubbed rendering, and never raises into the caller.
  it "logs a message holding invalid UTF-8 as a scrubbed line instead of raising" do
    io = StringIO.new
    log = wire_log_class.new(io, StringIO.new)
    bad = { method: "textDocument/didOpen", params: { text: "a\xFFb".b } }

    expect { log.record("<-", bad) }.not_to raise_error
    expect(io.string).to include("a\u{FFFD}b")
  end

  # An IO failure disables the log for the rest of the session; debug output goes to the fallback, never to the log.
  it "disables the wire log after an IO failure and sends debug output to the fallback" do
    io = StringIO.new
    fallback = StringIO.new
    log = wire_log_class.new(io, fallback)
    io.close

    expect { log.record("<-", { id: 1 }) }.not_to raise_error
    expect { log.write("debug line\n") }.not_to raise_error
    expect(fallback.string).to eq("debug line\n")
  end

  # An IO whose first write fails and whose later writes succeed: the log latches off after the failure.
  it "keeps the wire log off after the first failed write, even once the file would accept writes again" do
    flaky = Class.new do
      attr_reader :written

      def initialize
        @written = []
        @failed = false
      end

      def write(text)
        raise IOError, "gone" unless @failed

        @written << text
        text.bytesize
      ensure
        @failed = true
      end
    end.new
    fallback = StringIO.new
    log = wire_log_class.new(flaky, fallback)

    log.record("<-", { id: 1 })
    log.record("<-", { id: 2 })
    log.write("debug line\n")

    expect(flaky.written).to be_empty
    expect(fallback.string).to eq("debug line\n")
  end

  # A message nested past the JSON encoder's depth limit still gets its line, and the log stays enabled.
  it "logs a message nested past the encoder's depth limit and keeps the log enabled" do
    io = StringIO.new
    fallback = StringIO.new
    log = wire_log_class.new(io, fallback)
    deep = (1..120).reduce("leaf") { |acc, _| { "k" => acc } }

    expect { log.record("<-", deep) }.not_to raise_error
    expect(io.string).to match(/ <- ".*leaf/)
    log.write("still on\n")
    expect(io.string).to include("still on\n")
    expect(fallback.string).to be_empty
  end

  # `$stderr` under --log behaves as an IO for the callers that probe it (Bundler's shell, RubyGems' resolver).
  it "answers IO probes on $stderr under --log without raising" do
    Dir.mktmpdir("rigor-lsp-log-") do |dir|
      path = File.join(dir, "wire.log")
      command = described_class.new(argv: [], out: StringIO.new, err: StringIO.new)
      log = command.send(:open_wire_log, path)
      original_stderr = $stderr
      probes = nil
      loop_runner = instance_double(Rigor::LanguageServer::Loop)
      allow(loop_runner).to receive(:run) do
        probes = [$stderr.tty?, $stderr.closed?]
        $stderr.printf("printf marker %d\n", 7)
      end
      server = instance_double(Rigor::LanguageServer::Server, exit_code: 0)
      allow(command).to receive(:build_server).and_return([server, loop_runner])
      allow(LanguageServer::Protocol::Transport::Io::Reader).to receive(:new).and_return(StringIO.new)
      allow(LanguageServer::Protocol::Transport::Io::Writer).to receive(:new).and_return(StringIO.new)

      command.send(:serve, config_path: nil, log: log)
      expect($stderr).to be(original_stderr)
      log.close
      expect(probes).to eq([false, false])
      expect(File.read(path)).to include("printf marker 7")
    end
  end

  # A write-type call on a dead log goes through the never-raise path, not the file's own method.
  it "does not raise from printf on a closed log" do
    io = StringIO.new
    fallback = StringIO.new
    log = wire_log_class.new(io, fallback)
    io.close

    expect { log.printf("%s\n", "printed") }.not_to raise_error
    expect(fallback.string).to eq("printed\n")
  end
end
