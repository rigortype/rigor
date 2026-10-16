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
  let(:targets) { ["lib/shop.rb", "lib/order.rb", "lib/util.rb", "lib/point.rb", "lib/missing.rb", "README.md"] }

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
        def self.c = "s"
        module_function def c = 1
        def later = 3
      end
    RUBY
    _, out, = lens(["--format=json", "lib/t.rb"])
    basis = JSON.parse(out)["members"].to_h { |member| [[member["scope"], member["name"]], member["basis"]] }

    expect(basis).to include(%w[instance a] => "contested", %w[singleton a] => "contested",
                             %w[instance b] => "contested", %w[singleton b] => "contested",
                             %w[singleton c] => "contested")
    later = JSON.parse(out)["files"].first["sites"].find { |site| site["name"] == "later" }
    expect(later["visibility"]).to eq("public")
  end

  # #1998 review: when two files write a name, the declaration the environment kept says nothing about the other
  # file's site, whichever of them carries the annotation.
  it "reads an inline constant declaration only for a site in its own file" do
    File.write("lib/a.rb", "# rbs_inline: enabled\n\nmodule Two\n  AUTH = [] #: Array[String]\nend\n")
    File.write("lib/b.rb", "module Two\n  AUTH = [\"z\"]\nend\n")
    _, out, = lens(["--format=json", "lib/a.rb", "lib/b.rb"])
    files = JSON.parse(out)["files"]
    values = files.to_h { |file| [file["path"], file["sites"].find { it["kind"] == "constant" }["value"]] }

    expect(values["lib/a.rb"]).to include("type" => "::Array[::String]", "provenance" => "inline")
    expect(values["lib/b.rb"]).to eq("state" => "unavailable", "reason" => "not_computed")
  end

  def write_inline_constants
    File.write("lib/k.rb", <<~RUBY)
      # rbs_inline: enabled
      module K
        LIMIT = 10
        NUM = 1 #: Numeric
        Klass = Class.new(Order) { def own = 1 }
        Mod = ::Module.new
        Frozen = Class.new.freeze
        CALC = LIMIT.succ
        LIST = []
        LIST << 1
        WORDS = [] #: Array[String]
        #: Integer
        PRE = "x"
      end
    RUBY
  end

  # #1935 review: check reads a constant the source publishes as its value, over an rbs-inline declaration, and
  # a sig/ declaration over the value; a Class.new value is a new class, not the superclass the call returns.
  it "reads each constant's value the way check reads it" do
    write_inline_constants
    # Kept apart: a sig/ declaration of a constant in an rbs-inline file drops that file's inline RBS.
    File.write("lib/d.rb", "module K\n  DECL = \"x\"\n  R = 1\n  R = \"two\"\nend\n")
    File.write("sig/k.rbs", "module K\n  DECL: Integer\nend\n")
    _, out, err = lens(["--format=json", "lib/k.rb", "lib/d.rb"])
    values = JSON.parse(out)["files"].flat_map { |file| file["sites"] }.to_h { |site| [site["name"], site["value"]] }

    expect(err).not_to include("dropped inline-RBS")
    typed = values.slice("K::LIMIT", "K::NUM", "K::DECL", "K::WORDS").transform_values { it.slice("type", "provenance") }
    expect(typed)
      .to eq("K::LIMIT" => { "type" => "10", "provenance" => "inferred" },
             "K::NUM" => { "type" => "1", "provenance" => "inferred" },
             "K::DECL" => { "type" => "::Integer", "provenance" => "sig" },
             "K::WORDS" => { "type" => "::Array[::String]", "provenance" => "inline" })
    # Unannotated and unpublished: the rbs-inline plugin's literal default, which check reads too.
    expect(values.slice("K::LIST", "K::PRE").transform_values { it.slice("state", "type", "provenance") })
      .to eq("K::LIST" => { "state" => "typed", "type" => "Array[untyped]", "provenance" => "inferred" },
             "K::PRE" => { "state" => "typed", "type" => "String", "provenance" => "inferred" })
    expect(values["K::CALC"]).to include("state" => "dynamic", "provenance" => "inferred")
    expect(values.values_at("K::Klass", "K::Mod", "K::Frozen", "K::R"))
      .to all(eq("state" => "unavailable", "reason" => "not_computed"))
  end

  # An alias copies the def in place when it runs, and check reads the last def it saw, so the alias's overload
  # comes from the original only when that original has one project definition.
  it "reads an alias's overload from its original only when the original has one definition" do
    File.write("lib/a.rb", <<~RUBY)
      class A
        def one(x) = "\#{x}!"
        alias two one
        def three = 3
        alias four three
      end
    RUBY
    File.write("lib/b.rb", "class A\n  def three = :three\nend\n")
    _, out, = lens(["--format=json", "lib/a.rb"])
    overloads = JSON.parse(out)["members"].to_h { |member| [member["name"], member["overloads"]] }

    expect(overloads["two"].first).to include("rbs" => "(untyped x) -> String")
    expect(overloads["four"]).to eq([{ "rbs" => nil, "params" => nil, "block" => nil,
                                       "return" => { "state" => "unavailable", "reason" => "not_computed" } }])
  end

  # An RBS alias's contract is the alias's own, as check reads it; an alias across initialize copies no return.
  it "reads an RBS alias as a contract and an alias of initialize without its void" do
    File.write("lib/f.rb", <<~RUBY)
      class F
        def old = 1
        alias new old
        def initialize(v) = @v = v
        alias init2 initialize
      end
    RUBY
    File.write("sig/f.rbs", "class F\n  def old: () -> Integer\n  alias new old\nend\n")
    _, out, = lens(["--format=json", "lib/f.rb"])
    members = JSON.parse(out)["members"].to_h { |member| [member["name"], member] }

    expect(members["new"]).to include("basis" => "contract")
    expect(members["new"]["overloads"].map { |overload| overload["rbs"] }).to eq(["() -> ::Integer"])
    expect(members["init2"]["overloads"].first["return"]).to eq("state" => "unavailable", "reason" => "not_computed")
  end

  # rigortype/rigor#1907: a declared block's type read as `#<RBS::Types::Function:0x…>`.
  it "spells a declared block's function type as RBS writes it" do
    File.write("lib/blk.rb", <<~RUBY)
      class Blk
        def each_item = yield(1)
        def scoped(&) = instance_exec(&)
        def loose = yield
      end
    RUBY
    File.write("sig/blk.rbs", <<~RBS)
      class Blk
        def each_item: () { (Integer, ?String) -> void } -> void
        def scoped: () ?{ () [self: Blk] -> Integer } -> void
        def loose: () { (?) -> untyped } -> void
      end
    RBS
    _, out, = lens(["--format=json", "lib/blk.rb"])
    blocks = JSON.parse(out)["members"].to_h { |member| [member["name"], member["overloads"].first["block"]] }

    expect(blocks.transform_values { |block| [block["required"], block["type"]["type"]] })
      .to eq("each_item" => [true, "(::Integer, ?::String) -> void"],
             "scoped" => [false, "() [self: ::Blk] -> ::Integer"],
             "loose" => [true, "(?) -> untyped"])
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
