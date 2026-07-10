# frozen_string_literal: true

require "tmpdir"

require "rigor/cli/protection_fork_scan"
require "rigor/inference/protection_scanner"
require "rigor/scope"
require "rigor/configuration"

# P3-10 — direct coverage of the coverage-protection fork pool: sequential/fork result equivalence, parse-error
# sentinel handling, and one entry per path.
RSpec.describe Rigor::CLI::ProtectionForkScan do
  let(:scope) { Rigor::Scope.empty }
  let(:scanner) { Rigor::Inference::ProtectionScanner.new(scope: scope) }
  let(:configuration) { Rigor::Configuration.new({}) }

  around { |example| Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } } }

  # Writes `count` scannable source files into the (chdir'd) tmpdir and returns their paths.
  def write_sources(count)
    Array.new(count) do |i|
      path = "f#{i}.rb"
      File.write(path, "def m#{i}(x)\n  x.thing#{i}\nend\n")
      path
    end
  end

  def run(paths, workers)
    described_class.run(paths: paths, scanner: scanner, environment: scope.environment,
                        configuration: configuration, workers: workers)
  end

  it "returns one entry per path, keyed by path" do
    paths = write_sources(5)
    results = run(paths, 0)

    expect(results.keys).to match_array(paths)
    expect(results.values).to all(be_a(Rigor::Inference::ProtectionScanner::FileResult))
  end

  it "produces the same results forked as sequential" do
    skip "fork unavailable on this platform" unless Process.respond_to?(:fork)

    paths = write_sources(5)
    expect(run(paths, 3)).to eq(run(paths, 0))
  end

  it "records a parse error as a marshalable ParseError sentinel (forked and sequential agree)" do
    paths = write_sources(5)
    File.write("broken.rb", "def oops(\n")
    paths << "broken.rb"

    sequential = run(paths, 0)
    expect(sequential["broken.rb"]).to be_a(described_class::ParseError)
    expect(sequential["broken.rb"].count).to be >= 1

    expect(run(paths, 4)).to eq(sequential) if Process.respond_to?(:fork)
  end
end
