# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/language_server"
require "rigor/configuration"

# Issue #2231 — `ConfigAudit` warnings reached only `rigor check` and `rigor doctor`, so a user working in the editor
# with `undefined-method: "off"` in `.rigor.yml` (a key that does nothing) saw the error it was meant to silence and no
# hint why. The server now shows each warning as a `window/showMessage` once per configuration load: at `initialized`,
# and again only when a save round's reload changes the warning set.
RSpec.describe "Language server configuration warnings" do
  let(:writer) do
    Class.new do
      attr_reader :payloads

      def initialize
        @payloads = []
      end

      def write(payload)
        @payloads << payload
      end
    end.new
  end

  # Two inert entries: a top-level key the loader drops, and a `disable:` token that names no rule.
  let(:inert_config) do
    <<~YAML
      paths:
        - lib
      undefined-method: "off"
      disable:
        - call.undefined-methdo
    YAML
  end

  def shown_messages
    writer.payloads.select { |payload| payload[:method] == "window/showMessage" }.map { |payload| payload[:params] }
  end

  # The wiring `rigor lsp` builds (`CLI::LspCommand#build_server`), minus the debouncer so a save round runs inline.
  def boot_server(dir)
    config_path = File.join(dir, ".rigor.yml")
    context = Rigor::LanguageServer::ProjectContext.new(
      configuration: Rigor::Configuration.load(config_path),
      configuration_loader: -> { Rigor::Configuration.load(config_path) }
    )
    buffer_table = Rigor::LanguageServer::BufferTable.new
    publisher = Rigor::LanguageServer::DiagnosticPublisher.new(
      writer: writer, buffer_table: buffer_table, project_context: context
    )
    server = Rigor::LanguageServer::Server.new(buffer_table: buffer_table, publisher: publisher,
                                               project_context: context)
    server.dispatch("initialize", {})
    [server, publisher]
  end

  def with_project(config)
    Dir.mktmpdir("rigor-lsp-config-warnings-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "a.rb"), "x = 1\n")
      File.write(File.join(dir, ".rigor.yml"), config)
      Dir.chdir(dir) { yield dir }
    end
  end

  it "shows each warning as a window/showMessage warning on `initialized`" do
    with_project(inert_config) do |dir|
      server, = boot_server(dir)
      expect(shown_messages).to be_empty

      server.dispatch("initialized", {})

      expect(shown_messages.map { |params| params[:type] }).to eq([2, 2])
      expect(shown_messages.map { |params| params[:message] }).to contain_exactly(
        a_string_starting_with("rigor: `undefined-method` is not a recognized configuration key; it has no effect."),
        a_string_starting_with('rigor: disable: "call.undefined-methdo"').and(include("the suppression has no effect"))
      )
    end
  end

  it "does not repeat the warnings on a save round that reloads the same configuration" do
    with_project(inert_config) do |dir|
      server, publisher = boot_server(dir)
      server.dispatch("initialized", {})

      publisher.publish_project("file://#{File.join(dir, 'lib', 'a.rb')}")

      expect(shown_messages.size).to eq(2)
    end
  end

  it "shows the new warning when a save round's reload changes the warning set" do
    with_project(inert_config) do |dir|
      server, publisher = boot_server(dir)
      server.dispatch("initialized", {})
      File.write(File.join(dir, ".rigor.yml"), "paths:\n  - lib\nexcludee:\n  - vendor\n")

      publisher.publish_project("file://#{File.join(dir, 'lib', 'a.rb')}")

      expect(shown_messages.size).to eq(3)
      expect(shown_messages.last[:message]).to include("`excludee` is not a recognized configuration key")
        .and include("Did you mean `exclude`?")
    end
  end

  # Guard: no line of the fix can make a clean configuration announce something; this pins that it stays silent.
  it "shows nothing for a configuration with no warnings" do
    with_project("paths:\n  - lib\n") do |dir|
      server, = boot_server(dir)
      server.dispatch("initialized", {})

      expect(shown_messages).to be_empty
    end
  end
end
