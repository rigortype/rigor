# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #2480 — an existing `sig/` target that does not parse is REFUSED by `sig-gen --write`, and `--check` fails on it
# rather than reporting `sig/` up to date. The file itself is never touched.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  let(:config) do
    <<~YAML
      paths:
        - lib
    YAML
  end
  # Missing the closing `end`, so `RBS::Parser` rejects it. sig-gen proposes `Errors#y` for it.
  let(:unparseable_sig) { "class Errors\n  def existing: () -> String\n" }

  around { |example| Dir.chdir(root) { example.run } }

  before do
    write("lib/errors.rb", <<~RUBY)
      class Errors
        def y
          1
        end
      end
    RUBY
  end

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def sig_gen(*argv, paths: ["lib/errors.rb"])
    write(".rigor.yml", config)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: [*argv, "--config=#{File.join(root, '.rigor.yml')}", *paths],
                                 out: out, err: err).run
    [status, out.string, err.string]
  end

  def sig_file
    File.join(root, "sig/errors.rbs")
  end

  context "when the existing sig/ target does not parse" do
    before { write("sig/errors.rbs", unparseable_sig) }

    it "--check fails, names the file as REFUSED, and does not claim sig/ is up to date" do
      status, out, err = sig_gen("--check")

      expect(status).to eq(1)
      expect(out).to include("REFUSED").and include("sig/errors.rbs").and include("does not parse as RBS")
      expect(out).to match(%r{sig/errors\.rbs:\d+:\d+})
      expect(out).not_to include("up to date")
      # A refusal-only run has nothing `--write` would update, so it names the file for a hand fix and says nothing
      # about running `--write`.
      expect(err).to include("1 signature file(s) refused")
      expect(err).to match(%r{Repair by hand: \S*sig/errors\.rbs\.})
      expect(err).not_to include("out of date")
      expect(err).not_to include("run `rigor sig-gen --write`")
    end

    it "--write refuses it and leaves the file byte-for-byte untouched" do
      status, out, = sig_gen("--write")

      expect(status).to eq(1)
      expect(out).to include("REFUSED").and include("sig/errors.rbs")
      expect(File.read(sig_file)).to eq(unparseable_sig)
    end

    it "--format=json reports the refusal as skipped_unparseable, with the same keys as the other refusals" do
      status, out, = sig_gen("--write", "--format=json")
      entry = JSON.parse(out).fetch("results").first

      expect(status).to eq(1)
      expect(entry.fetch("action")).to eq("skipped_unparseable")
      expect(entry.fetch("error")).to include("sig/errors.rbs").and include("does not parse as RBS")
      expect(entry.fetch("error")).to match(%r{sig/errors\.rbs:\d+:\d+})
      expect(entry.keys).to contain_exactly("source", "target", "action", "applied", "skipped", "error")
      expect(File.read(sig_file)).to eq(unparseable_sig)
    end

    it "--check --format=json reports up_to_date false with the refusal listed" do
      status, out, = sig_gen("--check", "--format=json")
      payload = JSON.parse(out)

      expect(status).to eq(1)
      expect(payload.fetch("up_to_date")).to be(false)
      expect(payload.fetch("results").first.fetch("action")).to eq("skipped_unparseable")
    end
  end

  # A refusal is per target: the parseable and empty targets in the same run are still written, and the exit is 1.
  context "when one of three targets does not parse" do
    before do
      write("lib/a.rb", "class A\n  def a\n    1\n  end\nend\n") # new file: sig/a.rbs is created
      write("lib/b.rb", "class B\n  def b\n    2\n  end\nend\n")
      write("sig/b.rbs", "") # empty existing target: it parses, so it is updated
      write("sig/errors.rbs", unparseable_sig)
    end

    it "--write writes the other two, refuses the unparseable one, and exits 1" do
      status, out, = sig_gen("--write", paths: ["lib"])

      expect(status).to eq(1)
      expect(out).to include("REFUSED").and include("sig/errors.rbs")
      expect(File.read(File.join(root, "sig/a.rbs"))).to include("class A")
      expect(File.read(File.join(root, "sig/b.rbs"))).to include("class B")
      expect(File.read(sig_file)).to eq(unparseable_sig)
    end

    # The summary counts the two targets `--write` would update apart from the refused one, named for a hand fix.
    it "--check counts the pending targets as out of date and the refused one apart, and exits 1" do
      status, _out, err = sig_gen("--check", paths: ["lib"])

      expect(status).to eq(1)
      expect(err).to include("rigor sig-gen --check: 2 signature file(s) out of date; " \
                             "run `rigor sig-gen --write` with the same options to update them.")
      expect(err).to include("rigor sig-gen --check: 1 signature file(s) refused")
      expect(err).to match(%r{Repair by hand: \S*sig/errors\.rbs\.})
      expect(err.lines.grep(/out of date/).join).not_to include("errors.rbs")
      expect(File.exist?(File.join(root, "sig/a.rbs"))).to be(false)
      expect(File.read(sig_file)).to eq(unparseable_sig)
    end
  end

  # `skipped_invalid_rbs` is a generated file that does not parse: a Rigor rendering bug, not a file the user repairs.
  # The writer cannot be made to emit one from a real project, so the result is stubbed; the summary is what is pinned.
  context "when the generated RBS for a target does not parse (skipped_invalid_rbs)" do
    before do
      result = Rigor::SigGen::WriteResult.new(source_path: "lib/errors.rb", target_path: sig_file,
                                              action: :skipped_invalid_rbs, error: "generated RBS does not parse")
      allow(Rigor::SigGen::Writer).to receive(:new).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap { |writer| allow(writer).to receive(:write_all).and_return([result]) }
      end
    end

    it "--check counts it as refused with no hand-fix list and no trailing parenthesis, and exits 1" do
      status, _out, err = sig_gen("--check")

      expect(status).to eq(1)
      expect(err).to include("rigor sig-gen --check: 1 signature file(s) refused; `--write` does not update them.")
      expect(err).to include("a Rigor bug, see its REFUSED line on stdout.")
      expect(err).not_to include("Repair by hand")
      expect(err).not_to include("out of date")
      expect(err.chomp).to end_with("REFUSED line on stdout.")
    end
  end

  context "when the existing sig/ target parses and already declares the method" do
    before { write("sig/errors.rbs", "class Errors\n  def y: () -> 1\nend\n") }

    it "--check passes, and --write leaves the file unchanged" do
      original = File.read(sig_file)

      status, out, = sig_gen("--check")
      expect(status).to eq(0)
      expect(out).to include("up to date")

      expect(sig_gen("--write").first).to eq(0)
      expect(File.read(sig_file)).to eq(original)
    end
  end
end
