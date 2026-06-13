# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "rigor/configuration"
require "rigor/language_server/project_context"
require "rigor/protection/mutation_scanner"

# ADR-63 Tier 2 — the warm-loop per-file effectiveness measurement. Drives the
# real analyzer (one shared environment + project scan) over each mutant and
# reads a NEW diagnostic as a "caught breakage" (kill). This exercises the kill
# criterion end-to-end, so it builds a real (if minimal) project context.
RSpec.describe Rigor::Protection::MutationScanner do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def scanner
    config = Rigor::Configuration.load(nil)
    context = Rigor::LanguageServer::ProjectContext.new(configuration: config)
    described_class.new(
      configuration: config, environment: context.environment, project_scan: context.project_scan
    )
  end

  it "kills a renamed call on a concrete receiver (the breakage is caught)" do
    File.write("clean.rb", %(def greet\n  "hello".upcase\nend\n))

    result = scanner.scan_file("clean.rb")

    expect(result.killed).to be >= 1
    expect(result.survived).to eq(0)
    expect(result.ratio).to eq(1.0)
  end

  it "records a surviving site when a type-visible mutation is not caught" do
    # `File.join` accepts any arguments in RBS, so dropping an arg to nil does
    # not fire — a genuine missed-breakage candidate at a concrete receiver.
    File.write("joins.rb", %(def j\n  File.join("a", "b")\nend\n))

    result = scanner.scan_file("joins.rb")

    expect(result.survived).to be >= 1
    site = result.sites.first
    expect(site.method_name).to eq("join")
    expect(site.receiver).to be_a(String)
  end

  it "is vacuously fully effective for a file with no type-relevant mutations" do
    File.write("untyped.rb", %(def f(x)\n  x.save\nend\n))

    result = scanner.scan_file("untyped.rb")

    expect(result.total).to eq(0)
    expect(result.ratio).to eq(1.0)
  end
end
