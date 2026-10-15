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
    # A bundled plugin reports Rigor's version; any other version is a fact about the plugin, kept.
    context["plugins"].each { |plugin| plugin["version"] = "<version>" if plugin["version"] == Rigor::VERSION }
    document
  end

  # The fixture lists `rigor-rbs-inline` as a bare gem name, which the loader resolves through the gem→id memo
  # its first `require` records (ADR-88 WD4b). An earlier spec that required the plugin directly leaves that
  # memo empty and the suite empties the registry, so the plugin is registered and recorded by hand; without
  # this the document depends on spec order.
  before do
    require "rigor-rbs-inline"
    Rigor::Plugin.register(Rigor::Plugin::RbsInline) unless Rigor::Plugin.registered_for("rbs-inline")
    Rigor::Plugin.record_gem_registration("rigor-rbs-inline", ["rbs-inline"])
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
      expect(file["diagnostics"].map { |row| row.values_at("line", "column", "severity", "rule", "message") })
        .to eq(oracle.map { |row| row.values_at("line", "column", "severity", "rule", "message") })
    end
    expect(JSON.parse(out)["files"].sum { |file| file["diagnostics"].size }).to be_positive
  end

  it "answers a warm run with the same document, sharing the snapshot with check --incremental" do
    _, cold, cold_err = lens(["--format=json", *targets])
    _, warm, warm_err = lens(["--format=json", *targets])
    expect([cold_err, warm_err]).to match([/lens: cold/, /lens: warm/])
    expect(warm).to eq(cold)

    incremental_out = StringIO.new
    err = StringIO.new
    Rigor::CLI::CheckCommand.new(argv: ["--incremental", "--no-ci-detect", "--no-stats", "--format=json"],
                                 out: incremental_out, err: err).run
    no_cache_out = StringIO.new
    Rigor::CLI::CheckCommand.new(argv: ["--no-cache", "--no-ci-detect", "--no-stats", "--format=json"],
                                 out: no_cache_out, err: StringIO.new).run
    expect(err.string).to include("--incremental warm")
    expect(JSON.parse(incremental_out.string)["diagnostics"]).to eq(JSON.parse(no_cache_out.string)["diagnostics"])
  end

  it "captures the targets of a pooled cold run with one forced recheck" do
    _, sequential, = lens(["--format=json", "--workers=0", *targets])
    FileUtils.rm_rf(".rigor")
    rechecks = 0
    allow(Rigor::Analysis::IncrementalSession).to receive(:new).and_wrap_original do |original, **options|
      expect(options[:workers]).to eq(2)
      session = original.call(**options)
      allow(session).to receive(:recheck).and_wrap_original do |recheck|
        rechecks += 1
        recheck.call
      end
      session
    end
    _, pooled, = lens(["--format=json", "--workers=2", *targets])

    expect(rechecks).to eq(1)
    expect(pooled).to eq(sequential)
  end

  it "contains an error while reading a target: check's diagnostics and snapshot are untouched" do
    allow_any_instance_of(Rigor::Lens::FileReader).to receive(:read).and_raise("boom") # rubocop:disable RSpec/AnyInstance
    _, out, = lens(["--format=json", "--workers=0", "lib/order.rb"])
    file = JSON.parse(out)["files"].first
    expect(file).to include("status" => "failed", "reason" => "RuntimeError: boom")

    incremental_out = StringIO.new
    Rigor::CLI::CheckCommand.new(argv: ["--incremental", "--no-ci-detect", "--no-stats", "--format=json"],
                                 out: incremental_out, err: StringIO.new).run
    messages = JSON.parse(incremental_out.string)["diagnostics"].map { |row| row["message"] }
    expect(messages).to include(a_string_including("undefined method `upcase'"))
    expect(messages).not_to include(a_string_including("internal analyzer error"))
  end

  it "reads a file passed twice, in two spellings, once" do
    _, once, = lens(["--format=json", "lib/order.rb"])
    _, twice, = lens(["--format=json", "lib/order.rb", "./lib/order.rb"])

    document = JSON.parse(twice)
    keys = document["files"].flat_map { |file| (file["sites"] || []).map { |site| site["key"] } }

    expect(document["members"]).to eq(JSON.parse(once)["members"])
    expect(document["files"].map { |file| file["status"] }).to eq(%w[ok duplicate])
    expect(keys).to eq(keys.uniq)
  end

  it "still writes the document when the configured Ruby cannot be parsed" do
    File.write(".rigor.yml", File.read(".rigor.yml").sub('target_ruby: "3.4"', 'target_ruby: "3.2"'))
    status, out, = lens(["--format=json", "lib/order.rb"])
    file = JSON.parse(out)["files"].first

    expect(status).to eq(1)
    expect(file["status"]).to eq("failed")
    expect(file["reason"]).to include("3.2")
  end

  # rigortype/rigor#1907: the reported reproduction, end to end.
  it "reads a file with a trailing-comma multiple assignment" do
    File.write("lib/example.rb", "left, = [1, 2]\n")
    status, out, = lens(["--format=json", "lib/example.rb"])

    expect(status).to eq(0)
    expect(JSON.parse(out)["files"].first).to include("status" => "ok", "complete" => true)
  end

  # #1918 review: a module function's singleton copy runs with the module as self, so a return that flowed from
  # self (directly, through itself, or through another module function) is not the instance-scope type.
  it "does not give a module function's singleton copy a return that depends on self" do
    File.write("lib/m.rb", <<~RUBY)
      module M
        module_function
        def me = self
        def via = me
        def it = itself
        def num = 1
      end
    RUBY
    _, out, = lens(["--format=json", "lib/m.rb"])
    returns = JSON.parse(out)["members"].to_h do |member|
      [[member["scope"], member["name"]], member["overloads"].first["return"]]
    end

    expect(returns[%w[instance via]]).to include("state" => "typed", "type" => "M")
    %w[me via it].each do |name|
      expect(returns[["singleton", name]]).to eq("state" => "unavailable", "reason" => "not_computed")
    end
    expect(returns[%w[singleton num]]).to include("state" => "typed", "type" => "1")
  end

  # #1918 review: a named module_function's copy replaces an existing def self.x, so neither side is single-site.
  it "reads both sides of a member a named module_function names as contested" do
    File.write("lib/t.rb", <<~RUBY)
      module T
        NAMES = %i[a].freeze
        def self.a = "s"
        def a = 1
        module_function(*NAMES)
        def self.b = "s"
        def b = 1
        module_function :b
      end
    RUBY
    _, out, = lens(["--format=json", "lib/t.rb"])
    basis = JSON.parse(out)["members"].to_h { |member| [[member["scope"], member["name"]], member["basis"]] }

    expect(basis).to eq(%w[instance a] => "contested", %w[singleton a] => "contested",
                        %w[instance b] => "contested", %w[singleton b] => "contested")
  end

  it "exits 64 for a configuration file that does not exist" do
    status, out, = lens(["--config=nope.yml", "lib/order.rb"])

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(out).to be_empty
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
