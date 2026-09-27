# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# Issue #1436 — a `tighter-return` proposal changes the return and nothing else. It used to carry the `def`'s
# inferred parameter list (`untyped` everywhere, `(?)` spelled `(*untyped)`), which `--write --overwrite` then
# wrote over the declared one, and `--diff` showed the declaration as `() -> <return>`. Every surface a
# proposal reaches is pinned here: `--print`, `--diff`, the JSON payload, `--check` and `--write --overwrite`.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  let(:declared) do
    <<~RBS
      class C
        def m: (Integer x) -> untyped
        def n: (?) -> untyped
        def k: (Integer a, ?String b, *Symbol r, key: Integer, ?opt: String, **untyped) ?{ (Integer) -> void } -> untyped
        def t: (Integer x) -> Numeric
        def o: (Integer x) -> untyped
             | (String x) -> untyped
        def initialize: (Integer a) -> void
      end
    RBS
  end
  let(:kept) do
    {
      "m" => "def m: (Integer x) -> nil",
      "n" => "def n: (?) -> nil",
      "k" => "def k: (Integer a, ?String b, *Symbol r, key: Integer, ?opt: String, **untyped) " \
             "?{ (Integer) -> void } -> nil",
      "t" => "def t: (Integer x) -> Integer"
    }
  end

  around { |example| Dir.chdir(root) { example.run } }

  before do
    write("sig/c.rbs", declared)
    write("lib/c.rb", <<~RUBY)
      class C
        def initialize(a)
          @a = a
        end

        def m(x) = nil
        def n(*) = nil
        def k(a, b = "", *r, key:, opt: "", **kw, &blk) = nil
        def t(x) = x
        def o(x) = nil
      end
    RUBY
  end

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def sig_gen(*argv)
    write(".rigor.yml", "paths:\n  - lib\nsignature_paths:\n  - sig\n")
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: [*argv, "--config=#{File.join(root, '.rigor.yml')}", "lib/c.rb"],
                                 out: out, err: err).run
    [status, out.string, err.string]
  end

  def sig_file = File.read(File.join(root, "sig/c.rbs"))

  it "prints each proposal on its declared parameter list, and neither the overloaded member nor `initialize`" do
    _, out, = sig_gen("--print")

    expect(out).to include("  # [tighter, was: untyped]\n  def m: (Integer x) -> nil\n")
    expect(out).to include("  # [tighter, was: untyped]\n  def n: (?) -> nil\n")
    expect(out).to include("  # [tighter, was: Numeric]\n  def t: (Integer x) -> Integer\n")
    expect(out).to include("  #{kept['k']}\n")
    expect(out).not_to include("def o:")
    expect(out).not_to include("[new]")
    expect(out).not_to include("initialize")
  end

  it "shows the real declaration on the `-` line of `--diff`, not `() -> <declared return>`" do
    _, out, = sig_gen("--diff")

    expect(out).to include("- def m: (Integer x) -> untyped\n+ def m: (Integer x) -> nil\n")
    expect(out).to include("- def n: (?) -> untyped\n+ def n: (?) -> nil\n")
    expect(out).to include("- def t: (Integer x) -> Numeric\n+ def t: (Integer x) -> Integer\n")
    expect(out).not_to include("() -> untyped")
  end

  it "carries the kept parameters in the JSON `rbs` field, with the declared line beside it" do
    _, out, = sig_gen("--format=json")
    rows = JSON.parse(out).fetch("candidates").to_h { |row| [row.fetch("method"), row] }

    expect(rows.keys).to contain_exactly("m", "n", "k", "t")
    expect(rows.transform_values { |row| row.fetch("rbs") }).to eq(kept)
    expect(rows.fetch("n").fetch("declared_rbs")).to eq("def n: (?) -> untyped")
  end

  it "rewrites only the returns under `--write --overwrite`, leaving the overloads and `initialize` untouched" do
    status, = sig_gen("--write", "--overwrite")

    expect(status).to eq(0)
    expect(sig_file).to eq(<<~RBS)
      class C
        #{kept['m']}
        #{kept['n']}
        #{kept['k']}
        #{kept['t']}
        def o: (Integer x) -> untyped
             | (String x) -> untyped
        def initialize: (Integer a) -> void
      end
    RBS
  end

  it "lists the same replacements under `--check --overwrite`, and is up to date once they are written" do
    status, out, = sig_gen("--check", "--overwrite")

    expect(status).to eq(1)
    expect(out).to include("  - def m: (Integer x) -> untyped\n  + def m: (Integer x) -> nil\n")
    expect(out).to include("  - def n: (?) -> untyped\n  + def n: (?) -> nil\n")

    sig_gen("--write", "--overwrite")

    expect(sig_gen("--check", "--overwrite").first(2)).to eq([0, "sig/ is up to date\n"])
  end
end
