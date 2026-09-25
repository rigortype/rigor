# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# ADR-112 WD4 / #1076 — `sig-gen --check` is the CI freshness gate: it fails exactly when `--write` with the same
# flags would change `sig/`, and a member declared inline is part of what `--write` writes unless
# `sig_gen.inline_declared: skip` says otherwise.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  let(:plugin_config) do
    <<~YAML
      paths:
        - lib
      plugins:
        - gem: rigor-rbs-inline
          id: rbs-inline
          config:
            require_magic_comment: false
    YAML
  end

  around { |example| Dir.chdir(root) { example.run } }

  before do
    require "rigor-rbs-inline"
    Rigor::Plugin.register(Rigor::Plugin::RbsInline) unless Rigor::Plugin.registered_for("rbs-inline")
    write("lib/greeter.rb", greeter_source("String"))
  end

  after { FileUtils.remove_entry(root) }

  def greeter_source(param_type)
    <<~RUBY
      class Greeter
        # @rbs name: #{param_type}
        # @rbs return: String
        def greet(name)
          "Hello, \#{name}"
        end
      end
    RUBY
  end

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def sig_gen(*argv, config: plugin_config)
    write(".rigor.yml", config)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: [*argv, "--config=#{File.join(root, '.rigor.yml')}"], out: out, err: err).run
    [status, out.string, err.string]
  end

  # Probes `a3` / `a4`: method type parameters named differently on the two sides.
  def write_type_parameter_fixture
    write("lib/a.rb", <<~RUBY)
      class D
        #: [E] (E, untyped) -> Array[E]
        def pair(x, y) = [x, y]
      end

      class F
        #: [E] (E) -> Array[E]
        def each_one(x)
          yield x if block_given?
          [x]
        end
      end
    RUBY
    write("sig/a.rbs", <<~RBS)
      class D
        def pair: [T] (T x, T y) -> Array[T]
      end

      class F
        def each_one: [T] (T x) ?{ (T) -> void } -> Array[T]
      end
    RBS
  end

  def rigor_check_output(path)
    out = StringIO.new
    err = StringIO.new
    Rigor::CLI.start(["check", "--no-cache", "--config=#{File.join(root, '.rigor.yml')}", path], out: out, err: err)
    out.string + err.string
  end

  def sig_file
    File.join(root, "sig/greeter.rbs")
  end

  it "fails while sig/ lacks the inline-declared member, writes nothing, and passes once --write has run" do
    status, out, = sig_gen("--check")

    expect(status).to eq(1)
    expect(out).to include("sig/greeter.rbs").and include("+ def greet: (String name) -> String")
    expect(File.exist?(sig_file)).to be(false)

    expect(sig_gen("--write").first).to eq(0)
    expect(File.read(sig_file)).to include("def greet: (String name) -> String")

    status, out, = sig_gen("--check")
    expect(status).to eq(0)
    expect(out).to include("up to date")
  end

  it "refuses once the inline declaration changes, until --overwrite replaces the sig/ member" do
    sig_gen("--write")
    write("lib/greeter.rb", greeter_source("Symbol"))

    status, out, = sig_gen("--check")
    expect(status).to eq(1)
    expect(out).to include("REFUSED").and include("Greeter#greet").and include("sig.skipped.inline-differs")

    status, _out, err = sig_gen("--write")
    expect(status).to eq(1)
    expect(err).to include("REFUSED")
    expect(File.read(sig_file)).to include("def greet: (String name) -> String")

    expect(sig_gen("--check", "--overwrite").first).to eq(1)
    expect(sig_gen("--write", "--overwrite").first).to eq(0)
    expect(File.read(sig_file)).to include("def greet: (Symbol name) -> String")
    expect(File.read(sig_file)).not_to include("String name")
    expect(sig_gen("--check").first).to eq(0)
  end

  it "reports the verdict and the would-be results as JSON" do
    status, out, = sig_gen("--check", "--format=json")
    payload = JSON.parse(out)

    expect(status).to eq(1)
    expect(payload["up_to_date"]).to be(false)
    expect(payload["results"].map { |r| r["action"] }).to eq(["would_create"])
  end

  it "does not count a tighter return --write would decline, unless --overwrite asks for it" do
    write("lib/counter.rb", "class Counter\n  def n\n    rand(10)\n  end\nend\n")
    write("sig/counter.rbs", "class Counter\n  def n: () -> Numeric\nend\n")
    sig_gen("--write")

    expect(sig_gen("--check").first).to eq(0)
    expect(sig_gen("--check", "--overwrite").first).to eq(1)
  end

  # Review probe `f1` of #1422: a reviewed, hand-widened return on a parameter-only annotation disagrees with
  # the inline line, so it is refused — not narrowed — and sig/ stays byte-identical.
  it "refuses a hand-widened return on a parameter-only annotation, leaving sig/ untouched" do
    write("lib/chain.rb", <<~RUBY)
      class Chain
        # @rbs x: Integer
        def c(x) = x.to_s.size

        # @rbs name: String
        def pair(name) = [name, name.to_s]
      end
    RUBY
    sig = "class Chain\n  def c: (Integer x) -> Numeric\n  def pair: (String name) -> Array[String]\nend\n"
    write("sig/chain.rbs", sig)

    expect(sig_gen("--write", "lib/chain.rb").first).to eq(1)
    expect(File.read(File.join(root, "sig/chain.rbs"))).to eq(sig)
    expect(sig_gen("--check", "lib/chain.rb").first).to eq(1)
  end

  # Review probes `a3` / `a4` of #1422 (round 3): `--overwrite` replaces the whole member, so a method type
  # parameter is never taken from one side and its uses from the other.
  it "replaces whole members under --overwrite, leaving no unbound type variable" do
    write_type_parameter_fixture
    expect(sig_gen("--write", "lib/a.rb").first).to eq(1)
    expect(sig_gen("--write", "--overwrite", "lib/a.rb").first).to eq(0)

    written = File.read(File.join(root, "sig/a.rbs"))
    expect(written).to include("def pair: [E] (E, untyped) -> Array[E]")
      .and include("def each_one: [E] (E) -> Array[E]")
    # RBS parses an undeclared `T` as a class name, not a free variable, so the old parameter's absence is the check.
    expect(written).not_to match(/\bT\b/)
    expect { RBS::Parser.parse_signature(written) }.not_to raise_error
    expect(rigor_check_output("lib/a.rb")).not_to include("definition-build-failed")
    expect(sig_gen("--check", "lib/a.rb").first).to eq(0)
  end

  # Review of #1422 (probe `g_new`): the written `sig/` must build.
  it "writes a sig/ that builds when a class is generic by an inline declaration" do
    write("lib/box.rb", <<~RUBY)
      # @rbs generic T
      class Box
        #: () -> T
        def get = @v
      end

      class User
        #: () -> Box[Integer]
        def box = Box.new
      end
    RUBY
    sig_gen("--write", "lib/box.rb")

    expect(File.exist?(File.join(root, "sig/box.rbs"))).to be(true)
    expect(File.read(File.join(root, "sig/box.rbs"))).not_to include("class Box")

    expect(rigor_check_output("lib/box.rb")).not_to include("definition-build-failed")
    expect(sig_gen("--check", "lib/box.rb").first).to eq(0)
  end

  # Review probe `m2c` of #1422 (round 2): `sig/` keeps an overload the inline declaration does not mention. The
  # return would be inferred under that overload's parameters, so the refusal stands even under --overwrite.
  it "refuses, under --write, --check and --overwrite alike, a member whose overloads do not correspond" do
    write("lib/p.rb", <<~RUBY)
      class P
        # @rbs name: String
        def over_same(name) = name.size
      end
    RUBY
    sig = "class P\n  def over_same: (String name) -> Integer | (Integer name) -> Integer\nend\n"
    write("sig/p.rbs", sig)

    status, _out, err = sig_gen("--write", "lib/p.rb")
    expect(status).to eq(1)
    expect(err).to include("REFUSED").and include("P#over_same").and include("sig.skipped.inline-differs")
    expect(File.read(File.join(root, "sig/p.rbs"))).to eq(sig)
    expect(sig_gen("--write", "--overwrite", "lib/p.rb").first).to eq(1)
    expect(File.read(File.join(root, "sig/p.rbs"))).to eq(sig)

    status, out, = sig_gen("--check", "lib/p.rb")
    expect(status).to eq(1)
    expect(out).to include("REFUSED")

    status, out, = sig_gen("--check", "--format=json", "lib/p.rb")
    payload = JSON.parse(out)
    expect([status, payload["up_to_date"], payload["refused"].map { |r| r["method"] }]).to eq([1, false, ["over_same"]])
  end

  it "rejects --check alongside another mode" do
    status, _out, err = sig_gen("--check", "--write")

    expect(status).to eq(Rigor::CLI::EXIT_USAGE)
    expect(err).to include("mutually exclusive")
  end

  context "with sig_gen.inline_declared: skip" do
    let(:skip_config) { "#{plugin_config}sig_gen:\n  inline_declared: skip\n" }

    it "leaves the inline-declared member out of sig/ and counts it as a skip" do
      write("lib/plain.rb", "class Plain\n  def n\n    1\n  end\nend\n")

      status, _out, err = sig_gen("--write", config: skip_config)

      expect(status).to eq(0)
      expect(File.exist?(sig_file)).to be(false)
      expect(File.read(File.join(root, "sig/plain.rbs"))).to include("def n: () -> 1")
      expect(err).to include("left 1 method(s) declared inline out of sig/")
      expect(sig_gen("--check", config: skip_config).first).to eq(0)
    end
  end
end
