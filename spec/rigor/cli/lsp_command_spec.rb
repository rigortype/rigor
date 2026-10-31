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
end
