# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/language_server"

# ADR-124 follow-up — with `pre_eval:` configured, the editor publish replaced the project's literal constant table it
# took from its discovery seed with the `pre_eval:` publication alone, and it could not retract a listed constant an
# unlisted file also assigns (#663), because a `prebuilt:` runner keeps no writer census of its own. Each example
# compares the publish of `use.rb` with a cold `rigor check` of the same tree.
RSpec.describe "editor publish answers constants as rigor check under pre_eval (ADR-124)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-editor-pre-eval-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(
                               "paths" => [File.expand_path("lib")], "pre_eval" => [File.expand_path("lib/pe.rb")],
                               "workers" => 0
                             ))
  end

  def write_files(files)
    FileUtils.mkdir_p("lib")
    files.each { |name, source| File.write("lib/#{name}", source) }
  end

  def cold_rows
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    diagnostics = guarded_run(runner, [File.expand_path("lib")]).diagnostics
    diagnostics.select { |d| d.rule == "call.undefined-method" && File.basename(d.path) == "use.rb" }.map(&:line)
  end

  def publish_rows
    payloads = []
    writer = Object.new
    writer.define_singleton_method(:write) { |payload| payloads << payload }
    table = Rigor::LanguageServer::BufferTable.new
    context = Rigor::LanguageServer::ProjectContext.new(configuration: configuration)
    publisher = Rigor::LanguageServer::DiagnosticPublisher.new(writer: writer, buffer_table: table,
                                                               project_context: context)
    uri = "file://#{File.expand_path('lib/use.rb')}"
    table.open(uri: uri, bytes: File.read("lib/use.rb"), version: 1)
    publisher.publish_for(uri)
    payloads.last.dig(:params, :diagnostics).select { |d| d[:code] == "call.undefined-method" }
            .map { |d| d.dig(:range, :start, :line) + 1 }
  end

  it "keeps the literal constant table beside a pre_eval publication" do
    write_files("k.rb" => "module K\n  LIMIT = 3\nend\n", "pe.rb" => "module P\n  Y = 1\nend\n",
                "use.rb" => "K::LIMIT.upcase\n")
    expect(cold_rows).to eq([1])
    expect(publish_rows).to eq([1])
  end

  # A listed `X = 1` and an unlisted conditional `X = "s"`: `check` retracts the listed value, so `X.upcase` is not
  # a call on an Integer.
  it "retracts a pre_eval constant another file also assigns" do
    write_files("k.rb" => "X = \"s\" if ENV[\"A\"]\n", "pe.rb" => "X = 1\n", "use.rb" => "X.upcase\n")
    expect(cold_rows).to eq([])
    expect(publish_rows).to eq([])
  end
end
