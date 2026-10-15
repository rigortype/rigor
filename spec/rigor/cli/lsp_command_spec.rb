# frozen_string_literal: true

require "stringio"
require "rigor/cli"
require "rigor/cli/lsp_command"
require "rigor/configuration"
require "rigor/language_server"

RSpec.describe Rigor::CLI::LspCommand do
  # #1613 — a save round re-reads `.rigor.yml` through the loader the command wires in.
  it "wires a configuration_loader that re-loads the configuration at the given path" do
    command = described_class.new(argv: [], out: StringIO.new, err: StringIO.new)
    allow(Rigor::Configuration).to receive(:load).and_call_original

    server, = command.send(:build_server, writer: StringIO.new, config_path: "tmp-missing.yml")
    context = server.instance_variable_get(:@project_context)
    loader = context.instance_variable_get(:@configuration_loader)

    expect(loader).to be_a(Proc)
    loader.call
    expect(Rigor::Configuration).to have_received(:load).with("tmp-missing.yml").twice
  end
end
