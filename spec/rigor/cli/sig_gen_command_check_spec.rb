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

  it "fails again after the inline declaration changes, and --write brings the copy back in line" do
    sig_gen("--write")
    write("lib/greeter.rb", greeter_source("Symbol"))

    status, out, = sig_gen("--check")
    expect(status).to eq(1)
    expect(out).to include("- def greet: (String name) -> String").and include("+ def greet: (Symbol name) -> String")

    expect(sig_gen("--write").first).to eq(0)
    expect(File.read(sig_file)).to include("def greet: (Symbol name) -> String")
    expect(File.read(sig_file)).not_to include("String name")
    expect(sig_gen("--check").first).to eq(0)
  end

  it "reports the verdict and the would-be results as JSON" do
    status, out, = sig_gen("--check", "--format=json")
    payload = JSON.parse(out)

    expect(status).to eq(1)
    expect(payload["up_to_date"]).to be(false)
    expect(payload["results"].map { |r| r["action"] }).to eq(["created"])
  end

  it "does not count a tighter return --write would decline, unless --overwrite asks for it" do
    write("lib/counter.rb", "class Counter\n  def n\n    rand(10)\n  end\nend\n")
    write("sig/counter.rbs", "class Counter\n  def n: () -> Numeric\nend\n")
    sig_gen("--write")

    expect(sig_gen("--check").first).to eq(0)
    expect(sig_gen("--check", "--overwrite").first).to eq(1)
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
      expect(err).to include("sig.skipped.inline-declared: 1")
      expect(sig_gen("--check", config: skip_config).first).to eq(0)
    end
  end
end
