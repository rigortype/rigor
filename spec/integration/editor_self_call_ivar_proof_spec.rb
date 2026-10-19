# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/language_server"

# Issue #2147 — the editor's per-buffer publish (`Runner.new(buffer:, prebuilt: project_scan)`) ran no discovery
# pass, so a class another file declares read as an external ancestor there. The self-call ivar-write proof then
# gave up on `Base`, the class guard's narrowing of `@io` was dropped across `log("dumping")`, and the publish
# reported a `call.undefined-method` that `rigor check` over the same tree does not. The publish now seeds the
# cross-file discovery tables (`ProjectContext#discovery_seed_for`), with the buffer's own file re-walked.
RSpec.describe "editor publish answers as rigor check across files (#2147)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-editor-cross-file-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:caller_source) do
    <<~RUBY
      require "stringio"

      class Holder < Base
        def initialize = (@io = STDOUT)

        def dump
          return unless @io.is_a?(StringIO)

          log("dumping")
          @io.string
        end
      end
    RUBY
  end
  let(:base_source) { "class Base\n  def log(message) = warn(message)\nend\n" }
  # The configured spelling of the project root; `lib`, relative, is what a project without `paths:` gets.
  let(:configured_lib) { File.expand_path("lib") }
  let(:writing_base) { "class Base\n  def log(_message) = (@io = STDOUT)\nend\n" }

  def write(relative, contents)
    FileUtils.mkdir_p(File.dirname(relative))
    File.write(relative, contents)
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [configured_lib], "workers" => 0))
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    guarded_run(runner, [File.expand_path("lib")]).diagnostics
                                                  .select { |d| d.rule == "call.undefined-method" }.map do |d|
      [
        File.basename(d.path), d.line
      ]
    end.sort
  end

  def writer
    Class.new do
      attr_reader :payloads

      def initialize = (@payloads = [])
      def write(payload) = (@payloads << payload)
    end.new
  end

  # Opens `buffers` (`{relative path => bytes}`) and publishes them through the real publisher, one at a time or as
  # one batch, returning the `call.undefined-method` rows it pushed.
  def publish_rows(buffers, batch: false)
    out = writer
    table = Rigor::LanguageServer::BufferTable.new
    context = Rigor::LanguageServer::ProjectContext.new(configuration: configuration)
    publisher = Rigor::LanguageServer::DiagnosticPublisher.new(writer: out, buffer_table: table,
                                                               project_context: context)
    uris = buffers.map do |relative, bytes|
      uri = "file://#{File.expand_path(relative)}"
      table.open(uri: uri, bytes: bytes, version: 1)
      uri
    end
    batch ? publisher.publish_many(uris) : uris.each { |uri| publisher.publish_for(uri) }
    out.payloads.flat_map do |payload|
      name = File.basename(payload.dig(:params, :uri))
      payload.dig(:params, :diagnostics).select { |d| d[:code] == "call.undefined-method" }
             .map { |d| [name, d.dig(:range, :start, :line) + 1] }
    end.sort
  end

  it "keeps the narrowing across a call to a callee another file declares" do
    write("lib/b.rb", base_source)
    write("lib/a.rb", caller_source)
    expect(cold_rows).to eq([])
    expect(publish_rows({ "lib/a.rb" => caller_source })).to eq([])
  end

  it "keeps it in a batch publish as well" do
    write("lib/b.rb", base_source)
    write("lib/a.rb", caller_source)
    expect(publish_rows({ "lib/a.rb" => caller_source, "lib/b.rb" => base_source }, batch: true)).to eq([])
  end

  # The positive control: the same publish still reports when the cross-file callee writes the variable.
  it "drops the narrowing when the callee another file declares writes the variable" do
    write("lib/b.rb", writing_base)
    write("lib/a.rb", caller_source)
    expect(cold_rows).to eq([["a.rb", 10]])
    expect(publish_rows({ "lib/a.rb" => caller_source })).to eq([["a.rb", 10]])
  end

  # The buffer's own declarations win over its bytes on disk: a `def` the buffer deleted but the file on disk still
  # holds must not reach the publish through the seed's walk of that file.
  it "drops a definition the buffer deleted from its file" do
    write("lib/b.rb", base_source)
    write("lib/a.rb", caller_source.sub("  def dump", "  def log(_message) = (@io = STDOUT)\n\n  def dump"))
    expect(cold_rows).to eq([["a.rb", 12]])
    expect(publish_rows({ "lib/a.rb" => caller_source })).to eq([])
  end

  # The buffer's URI is absolute while the configured path is relative: the buffer's file must still be re-walked
  # from the buffer's bytes rather than read from disk under the configured spelling.
  context "with the default relative `lib`" do
    let(:configured_lib) { "lib" }

    it "drops a definition the buffer deleted from its file" do
      write("lib/b.rb", base_source)
      write("lib/a.rb", caller_source.sub("  def dump", "  def log(_message) = (@io = STDOUT)\n\n  def dump"))
      expect(publish_rows({ "lib/a.rb" => caller_source })).to eq([])
    end
  end

  # A second configured root that aliases the first through a symlink reaches the buffer's file under another
  # spelling, which must not fold it from disk either.
  context "with a second root that is a symlink to the first" do
    def configuration
      Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(
                                 "paths" => [File.expand_path("lib"), File.expand_path("src")], "workers" => 0
                               ))
    end

    # `Base` and `A` are declared under both roots, so the self-call proof gives up either way; the buffer's file
    # is read through the override it deleted instead (the review's repro).
    it "reads the buffer's file under both spellings" do
      write("lib/base.rb", "class Base\n  def name = \"s\"\nend\n")
      write("lib/a.rb", "class A < Base\n  def name = 1\nend\n")
      File.symlink(File.expand_path("lib"), "src")
      buffer = "class A < Base\n  def shout = name.upcase\nend\n"
      expect(publish_rows({ "lib/a.rb" => buffer })).to eq([])

      write("lib/a.rb", buffer)
      expect(cold_rows).to eq([])
    end
  end
end
