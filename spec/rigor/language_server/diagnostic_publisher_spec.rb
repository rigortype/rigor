# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"

RSpec.describe Rigor::LanguageServer::DiagnosticPublisher do
  # In-memory writer collecting every payload pushed to it. Mirrors
  # `LanguageServer::Protocol::Transport::Io::Writer#write` but captures the raw Hash so specs can inspect the wire
  # shape without re-parsing.
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

  let(:buffer_table) { Rigor::LanguageServer::BufferTable.new }
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:project_context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }
  let(:publisher) do
    described_class.new(writer: writer, buffer_table: buffer_table, project_context: project_context)
  end

  describe "#publish_for" do
    it "no-ops when the URI isn't a file:// scheme" do
      publisher.publish_for("untitled:foo")
      expect(writer.payloads).to be_empty
    end

    it "no-ops when the buffer isn't open in the table" do
      publisher.publish_for("file:///not/in/table.rb")
      expect(writer.payloads).to be_empty
    end

    it "publishes an EMPTY set for a buffer the server could not keep in sync" do
      Dir.mktmpdir("rigor-lsp-desync-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)
        # A malformed range edit: the table keeps the old text and marks the URI desynchronised.
        buffer_table.apply_changes(
          uri: uri,
          changes: [{ range: { start: { line: 0 }, end: { line: 0, character: 0 } }, text: "x" }],
          version: 2
        )

        Dir.chdir(tmpdir) { publisher.publish_for(uri) }

        # Markers are cleared rather than left pointing at spans computed from text that has drifted.
        expect(writer.payloads.size).to eq(1)
        expect(writer.payloads.first.dig(:params, :diagnostics)).to eq([])
      end
    end

    it "pushes one `textDocument/publishDiagnostics` notification per call" do
      Dir.mktmpdir("rigor-lsp-publish-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        # Buffer has a parse error — should surface as an LSP diagnostic mapped from Rigor's :error severity.
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)

        Dir.chdir(tmpdir) { publisher.publish_for(uri) }

        expect(writer.payloads.size).to eq(1)
        msg = writer.payloads.first
        expect(msg[:method]).to eq("textDocument/publishDiagnostics")
        expect(msg.dig(:params, :uri)).to eq(uri)
        diagnostics = msg.dig(:params, :diagnostics)
        expect(diagnostics).not_to be_empty
        expect(diagnostics.first[:severity]).to eq(1) # LSP Error
        expect(diagnostics.first[:source]).to eq("rigor")
      end
    end

    it "uses 0-based line / character positions per LSP spec" do
      Dir.mktmpdir("rigor-lsp-publish-zerobased-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        # Parse error fires on line 1 of the buffer; LSP expects line: 0 (0-based).
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)

        Dir.chdir(tmpdir) { publisher.publish_for(uri) }

        diag = writer.payloads.first.dig(:params, :diagnostics).first
        # Rigor: line 1, col 11 (1-based). LSP: line 0, character 10.
        expect(diag[:range][:start][:line]).to be >= 0
        expect(diag[:range][:start][:character]).to be >= 0
      end
    end
  end

  describe "debouncer integration (slice 8)" do
    let(:debouncer) { Rigor::LanguageServer::Debouncer.new }
    let(:debounced_publisher) do
      described_class.new(
        writer: writer, buffer_table: buffer_table, project_context: project_context,
        debouncer: debouncer, debounce_seconds: 0
      )
    end

    it "delivers exactly ONE notification for a burst of publish_for calls (last write wins)" do
      Dir.mktmpdir("rigor-lsp-debounce-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        buffer_table.open(uri: uri, bytes: "x = 1\n", version: 1)

        Dir.chdir(tmpdir) do
          # Five rapid publish_for calls — only one should fire.
          5.times { debounced_publisher.publish_for(uri) }
          debouncer.flush!
        end

        expect(writer.payloads.size).to eq(1)
      end
    end

    it "drops the publish when the buffer is closed during the debounce window" do
      Dir.mktmpdir("rigor-lsp-debounce-close-") do |tmpdir|
        path = File.join(tmpdir, "foo.rb")
        uri = "file://#{path}"
        buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)

        # Schedule with a small delay so we can close before fire.
        publisher_with_delay = described_class.new(
          writer: writer, buffer_table: buffer_table, project_context: project_context,
          debouncer: debouncer, debounce_seconds: 0.05
        )
        Dir.chdir(tmpdir) do
          publisher_with_delay.publish_for(uri)
          buffer_table.close(uri: uri) # close before debounce fires
          debouncer.flush!
        end

        expect(writer.payloads).to be_empty
      end
    end
  end

  describe "#to_lsp_diagnostic" do
    it "converts 1-based Rigor positions to 0-based LSP positions" do
      diag = Rigor::Analysis::Diagnostic.new(
        path: "/a.rb", line: 3, column: 7, message: "test",
        severity: :error, rule: "x"
      )
      result = publisher.send(:to_lsp_diagnostic, diag, "/a.rb")
      expect(result[:range][:start][:line]).to eq(2)
      expect(result[:range][:start][:character]).to eq(6)
    end

    it "returns nil when the diagnostic path does not match buffer_path" do
      diag = Rigor::Analysis::Diagnostic.new(
        path: "/other.rb", line: 1, column: 1, message: "test",
        severity: :error, rule: "x"
      )
      expect(publisher.send(:to_lsp_diagnostic, diag, "/a.rb")).to be_nil
    end

    it "uses SEVERITY_MAP and falls back to :info (3) for unmapped severities" do
      diag = Rigor::Analysis::Diagnostic.new(
        path: "/a.rb", line: 1, column: 1, message: "test",
        severity: :unknown_tier, rule: "x"
      )
      result = publisher.send(:to_lsp_diagnostic, diag, "/a.rb")
      expect(result[:severity]).to eq(3)
    end
  end

  describe "#cancel_pending" do
    let(:debouncer) { Rigor::LanguageServer::Debouncer.new }
    let(:debounced_publisher) do
      described_class.new(
        writer: writer, buffer_table: buffer_table, project_context: project_context,
        debouncer: debouncer, debounce_seconds: 0.5
      )
    end

    it "cancels in-flight debounced tasks" do
      buffer_table.open(uri: "file:///tmp/x.rb", bytes: "x = 1", version: 1)
      debounced_publisher.publish_for("file:///tmp/x.rb")
      debounced_publisher.cancel_pending

      # Wait past the original delay window; no notification fires.
      sleep 0.05
      expect(writer.payloads).to be_empty
    end
  end

  describe "#publish_empty" do
    it "pushes an empty diagnostics array for the URI" do
      publisher.publish_empty("file:///x.rb")

      expect(writer.payloads).to eq([
                                      {
                                        method: "textDocument/publishDiagnostics",
                                        params: { uri: "file:///x.rb", diagnostics: [] }
                                      }
                                    ])
    end
  end

  # #246 — the save round. Analysis scope is the whole project; the PUBLISH SET is the open, clean buffers.
  describe "#publish_project" do
    # `widget.rb` returns a String and `other.rb` calls `upcase` on it — clean. Editing widget's return to an
    # Integer makes the diagnostic appear in OTHER.rb, which is the whole point: a single-file publish for
    # widget can never report it.
    def write_project(dir, widget_body)
      File.write(File.join(dir, "widget.rb"), "class Widget\n  def name\n    #{widget_body}\n  end\nend\n")
      File.write(File.join(dir, "other.rb"), "class Other\n  def go\n    Widget.new.name.upcase\n  end\nend\n")
    end

    def context_for(dir)
      Rigor::LanguageServer::ProjectContext.new(
        configuration: Rigor::Configuration.new("paths" => [dir])
      )
    end

    def publisher_for(context)
      described_class.new(writer: writer, buffer_table: buffer_table, project_context: context)
    end

    def diagnostics_for(uri)
      payload = writer.payloads.rfind { |p| p.dig(:params, :uri) == uri }
      payload&.dig(:params, :diagnostics)
    end

    it "publishes a saved file's effect on a dependent that is open in another buffer" do
      Dir.mktmpdir("rigor-lsp-round-") do |dir|
        write_project(dir, "1")
        widget = "file://#{File.join(dir, 'widget.rb')}"
        other  = "file://#{File.join(dir, 'other.rb')}"
        buffer_table.open(uri: widget, bytes: File.read(File.join(dir, "widget.rb")), version: 1)
        buffer_table.open(uri: other, bytes: File.read(File.join(dir, "other.rb")), version: 1)

        Dir.chdir(dir) { publisher_for(context_for(dir)).publish_project(widget) }

        expect(diagnostics_for(other)).not_to be_empty
        expect(diagnostics_for(other).first[:message]).to include("undefined method `upcase'")
        # The saved buffer itself is clean, so it is published too — with its own (empty) slice.
        expect(diagnostics_for(widget)).to eq([])
      end
    end

    it "excludes a dirty buffer, whose markers only its own analysis may set" do
      Dir.mktmpdir("rigor-lsp-round-dirty-") do |dir|
        write_project(dir, "1")
        widget = "file://#{File.join(dir, 'widget.rb')}"
        other  = "file://#{File.join(dir, 'other.rb')}"
        buffer_table.open(uri: widget, bytes: File.read(File.join(dir, "widget.rb")), version: 1)
        buffer_table.open(uri: other, bytes: File.read(File.join(dir, "other.rb")), version: 1)
        # The user is mid-edit in other.rb — this round analysed the file on DISK, so it may not speak for it.
        buffer_table.change(uri: other, bytes: "class Other\nend\n", version: 2)

        Dir.chdir(dir) { publisher_for(context_for(dir)).publish_project(widget) }

        expect(diagnostics_for(other)).to be_nil
        expect(diagnostics_for(widget)).to eq([])
      end
    end

    it "publishes nothing when the context was invalidated while the round ran" do
      Dir.mktmpdir("rigor-lsp-round-gen-") do |dir|
        write_project(dir, "1")
        widget = "file://#{File.join(dir, 'widget.rb')}"
        buffer_table.open(uri: widget, bytes: File.read(File.join(dir, "widget.rb")), version: 1)
        context = context_for(dir)
        # A watched-file change lands mid-analysis: the world these diagnostics describe is gone.
        allow(context).to receive(:project_diagnostics).and_wrap_original do |original, *args|
          result = original.call(*args)
          context.invalidate!
          result
        end

        Dir.chdir(dir) { publisher_for(context).publish_project(widget) }

        expect(writer.payloads).to be_empty
      end
    end

    it "runs one round at a time and collapses a burst into one extra round" do
      Dir.mktmpdir("rigor-lsp-round-flight-") do |dir|
        write_project(dir, '"w"')
        widget = "file://#{File.join(dir, 'widget.rb')}"
        buffer_table.open(uri: widget, bytes: File.read(File.join(dir, "widget.rb")), version: 1)
        context = context_for(dir)
        publisher = publisher_for(context)
        rounds = 0
        concurrent = false
        running = false
        allow(context).to receive(:project_diagnostics).and_wrap_original do |original, *args|
          concurrent ||= running
          running = true
          rounds += 1
          # Re-entering while this round is in flight must NOT start a second one.
          publisher.publish_project(widget) if rounds == 1
          result = original.call(*args)
          running = false
          result
        end

        Dir.chdir(dir) { publisher.publish_project(widget) }

        expect(concurrent).to be(false)
        expect(rounds).to eq(2) # the in-flight round plus exactly one re-run for the save that arrived
      end
    end
  end
end
