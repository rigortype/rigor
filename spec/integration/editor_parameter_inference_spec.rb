# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/language_server"

# ADR-124 follow-up — under `parameter_inference:` the editor publish collected the ADR-67 call-site table over the
# buffer's file alone, so a parameter another file calls with an Integer read `Dynamic[top]` there while `rigor check`
# types it `Integer`. The publish now takes the whole-project table `ProjectContext#param_inferred_types` builds once
# per generation.
RSpec.describe "editor publish types inferred parameters as rigor check (ADR-124)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-editor-param-inference-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:callee) { "class Greeter\n  def greet(name) = dump_type(name)\nend\n" }

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(
                               "paths" => [File.expand_path("lib")], "parameter_inference" => true, "workers" => 0
                             ))
  end

  def write_files(files)
    FileUtils.mkdir_p("lib")
    files.each { |name, source| File.write("lib/#{name}", source) }
  end

  def cold_types
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    diagnostics = guarded_run(runner, [File.expand_path("lib")]).diagnostics
    diagnostics.select { |d| d.path.end_with?("a.rb") && d.rule == "dump.type" }.map(&:message)
  end

  def publish_types(batch: false)
    payloads = []
    writer = Object.new
    writer.define_singleton_method(:write) { |payload| payloads << payload }
    table = Rigor::LanguageServer::BufferTable.new
    context = Rigor::LanguageServer::ProjectContext.new(configuration: configuration)
    publisher = Rigor::LanguageServer::DiagnosticPublisher.new(writer: writer, buffer_table: table,
                                                               project_context: context)
    uris = %w[a.rb b.rb].map { |name| "file://#{File.expand_path("lib/#{name}")}" }
    uris.each { |uri| table.open(uri: uri, bytes: File.read(uri.delete_prefix("file://")), version: 1) }
    batch ? publisher.publish_many(uris) : publisher.publish_for(uris.first)
    payload = payloads.rfind { |p| p.dig(:params, :uri) == uris.first }
    payload.dig(:params, :diagnostics).select { |d| d[:code] == "dump.type" }.map { |d| d[:message] }
  end

  it "types a parameter another file's call site fixes" do
    write_files("a.rb" => callee, "b.rb" => "Greeter.new.greet(1)\n")
    expect(cold_types).to eq(["dump_type: Integer"])
    expect(publish_types).to eq(cold_types)
  end

  it "types it in a batch publish as well" do
    write_files("a.rb" => callee, "b.rb" => "Greeter.new.greet(1)\n")
    expect(publish_types(batch: true)).to eq(["dump_type: Integer"])
  end
end
