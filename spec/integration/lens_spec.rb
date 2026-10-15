# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor/cli/lens_command"
require "rigor/cli/check_command"

# `rigor lens` over the shared fixture project (docs/internal-spec/lens.md). The expected document is the
# revision-1 fixture ZARD's adapter pins; regenerate it with `RIGOR_LENS_FIXTURE_WRITE=1` after a deliberate
# change and review the diff.
RSpec.describe "rigor lens" do
  let(:fixture) { File.expand_path("fixtures/lens", __dir__) }
  let(:expected_path) { File.join(fixture, "expected.json") }
  let(:targets) { ["lib/shop.rb", "lib/order.rb", "lib/util.rb", "lib/missing.rb", "README.md"] }

  def lens(argv)
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI::LensCommand.new(argv: argv, out: out, err: err).run
    [status, out.string, err.string]
  end

  # Fields that name the engine or the machine rather than the fixture.
  def normalize(document)
    document = JSON.parse(JSON.generate(document))
    document["producer"].merge!("version" => "<version>", "engine_source" => "<engine>")
    context = document["context"]
    context.merge!("rbs_version" => "<rbs>", "digest" => "<digest>")
    context["plugins"].each { |plugin| plugin["version"] = "<version>" }
    document
  end

  around do |example|
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(fixture, "project", "."), dir)
      File.write(File.join(dir, "README.md"), "not Ruby\n")
      Dir.chdir(dir) { example.run }
    end
  end

  it "emits the revision-1 fixture document" do
    status, out, = lens(["--format=json", *targets])
    document = normalize(JSON.parse(out))

    if ENV["RIGOR_LENS_FIXTURE_WRITE"]
      File.write(expected_path, "#{JSON.pretty_generate(document)}\n")
      skip "rewrote #{expected_path}"
    end

    expect(status).to eq(0)
    expect(document).to eq(JSON.parse(File.read(expected_path)))
  end

  it "reports each target's diagnostics exactly as rigor check --no-cache does" do
    _, out, = lens(["--format=json", "lib/shop.rb", "lib/order.rb"])
    check_out = StringIO.new
    Rigor::CLI::CheckCommand.new(argv: ["--no-cache", "--no-ci-detect", "--no-stats", "--format=json"],
                                 out: check_out, err: StringIO.new).run
    check_rows = JSON.parse(check_out.string)["diagnostics"]

    JSON.parse(out)["files"].each do |file|
      oracle = check_rows.select { |row| File.expand_path(row["path"]) == File.expand_path(file["path"]) }
      expect(file["diagnostics"].map { |row| row.values_at("line", "column", "message") })
        .to eq(oracle.map { |row| row.values_at("line", "column", "message") })
    end
    expect(JSON.parse(out)["files"].sum { |file| file["diagnostics"].size }).to be_positive
  end

  it "answers a warm run with the same document, sharing the snapshot with check --incremental" do
    _, cold, = lens(["--format=json", *targets])
    _, warm, = lens(["--format=json", *targets])
    expect(warm).to eq(cold)

    err = StringIO.new
    Rigor::CLI::CheckCommand.new(argv: ["--incremental", "--no-ci-detect", "--no-stats"],
                                 out: StringIO.new, err: err).run
    expect(err.string).to include("--incremental warm")
  end

  it "captures the targets of a pooled cold run with one forced recheck" do
    _, sequential, = lens(["--format=json", "--workers=0", *targets])
    FileUtils.rm_rf(".rigor")
    _, pooled, = lens(["--format=json", "--workers=2", *targets])

    expect(pooled).to eq(sequential)
  end

  it "exits 1 when no target has a result, and still writes the document" do
    status, out, = lens(["--format=json", "lib/missing.rb"])

    expect(status).to eq(1)
    expect(JSON.parse(out)["files"].map { |file| file["status"] }).to eq(["not_found"])
  end

  it "exits 64 without a target" do
    status, out, err = lens([])

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(out).to be_empty
    expect(err).to include("no FILE given")
  end

  it "reports a file that does not parse with its diagnostics" do
    File.write("lib/broken.rb", "class Broken\n  def x(\nend\n")
    status, out, = lens(["--format=json", "lib/broken.rb"])
    file = JSON.parse(out)["files"].first

    expect(status).to eq(1)
    expect(file).to include("status" => "parse_error", "sites" => nil)
    expect(file["diagnostics"]).not_to be_empty
  end

  it "renders text with each site's anchor token" do
    status, out, = lens(["lib/shop.rb"])

    expect(status).to eq(0)
    expect(out).to match(/^  \d+:\h{4}  class Shop$/)
    expect(out).to include("Shop#label: (::Integer n) -> ::String  [contract inline]")
  end
end
