# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #1676 — a plain top-level `def` is a visible candidate classified `skipped`, not a silent absence, and it
# changes neither what `--write` writes nor what `--check` decides.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  around { |example| Dir.chdir(root) { example.run } }

  before do
    write("lib/crt.rb", "def crt(r, m) = [0, 0]\n")
    write("lib/foo.rb", "class Foo\n  def bar = 1\nend\n")
    write(".rigor.yml", "paths:\n  - lib\n")
  end

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def sig_gen(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: [*argv, "--config=#{File.join(root, '.rigor.yml')}"], out: out, err: err).run
    [status, out.string, err.string]
  end

  it "lists the top-level def as skipped in --format=json" do
    _status, out, = sig_gen("--format=json", "lib")
    rows = JSON.parse(out).fetch("candidates")

    expect(rows.map { |r| r["method"] }).to contain_exactly("bar", "crt")
    expect(rows.find { |r| r["method"] == "crt" }).to include(
      "file" => a_string_ending_with("lib/crt.rb"), "classification" => "skipped",
      "skip_reason" => "sig.skipped.top-level-def"
    ).and(satisfy { |r| !r.key?("class") && !r.key?("rbs") })
  end

  it "counts it in the text summary" do
    _status, _out, err = sig_gen("lib")

    expect(err).to include("sig.skipped.top-level-def: 1")
  end

  it "writes no file for it and leaves --check's status to the emittable candidates" do
    expect(sig_gen("--write", "lib").first).to eq(0)
    expect(Dir.glob("sig/**/*.rbs").map { |f| File.read(f) }.join).not_to include("crt")
    expect(sig_gen("--check", "lib").first).to eq(0)
  end
end
