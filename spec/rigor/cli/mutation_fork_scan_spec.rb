# frozen_string_literal: true

require "tmpdir"

require "rigor/cli/mutation_fork_scan"
require "rigor/configuration"
require "rigor/language_server/project_context"
require "rigor/protection/mutation_scanner"

# Issue #134 slice 1 — direct coverage of the ADR-63 Tier 2 fork pool: sequential/fork result equivalence,
# parse-error sentinel handling, and one entry per path. Mirrors `protection_fork_scan_spec.rb`, the Tier 1
# proof of the same contract.
RSpec.describe Rigor::CLI::MutationForkScan do
  let(:configuration) { Rigor::Configuration.new({}) }
  let(:context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }
  let(:scanner) do
    Rigor::Protection::MutationScanner.new(
      configuration: configuration, environment: context.environment, project_scan: context.project_scan
    )
  end

  around { |example| Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } } }

  # Writes `count` measurable source files into the (chdir'd) tmpdir and returns their paths. Each carries a
  # concrete-receiver dispatch site, so the biteable filter keeps at least one mutation per file.
  def write_sources(count)
    Array.new(count) do |i|
      path = "f#{i}.rb"
      File.write(path, %(def m#{i}\n  "hello#{i}".upcase\nend\n))
      path
    end
  end

  def run(paths, workers)
    described_class.run(paths: paths, scanner: scanner, environment: context.environment,
                        configuration: configuration, workers: workers)
  end

  it "returns one entry per path, keyed by path" do
    paths = write_sources(3)
    results = run(paths, 0)

    expect(results.keys).to match_array(paths)
    expect(results.values).to all(be_a(Rigor::Protection::MutationScanner::FileResult))
  end

  it "produces the same results forked as sequential" do
    skip "fork unavailable on this platform" unless Process.respond_to?(:fork)

    paths = write_sources(4)
    expect(run(paths, 3)).to eq(run(paths, 0))
  end

  it "measures something — the equivalence assertion would be vacuous over empty results" do
    results = run(write_sources(1), 0)

    expect(results.fetch("f0.rb").total).to be >= 1
  end

  it "records a parse error as a marshalable ParseError sentinel (forked and sequential agree)" do
    paths = write_sources(3)
    File.write("broken.rb", "def oops(\n")
    paths << "broken.rb"

    sequential = run(paths, 0)
    expect(sequential["broken.rb"]).to be_a(described_class::ParseError)
    expect(sequential["broken.rb"].count).to be >= 1

    expect(run(paths, 4)).to eq(sequential) if Process.respond_to?(:fork)
  end
end
