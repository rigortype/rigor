# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #2576 — a `sig/` target the writer cannot write is a usage error, the same rule `rigor init --path`
# follows (#2562): one `rigor sig-gen: cannot write PATH: REASON` line on stderr and exit 64. The
# write used to escape as a raw Errno backtrace, which read as an internal crash.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  let(:config) do
    <<~YAML
      paths:
        - lib
    YAML
  end

  around { |example| Dir.chdir(root) { example.run } }

  before do
    write("lib/errors.rb", <<~RUBY)
      class Errors
        def y
          1
        end
      end
    RUBY
    write(".rigor.yml", config)
  end

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def sig_gen(*argv, paths: ["lib/errors.rb"])
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: [*argv, "--config=#{File.join(root, '.rigor.yml')}", *paths],
                                 out: out, err: err).run
    [status, out.string, err.string]
  end

  # The writer reports the target as an absolute path under the project root; `Dir.pwd` inside the
  # example is the same spelling the command sees (the around hook already chdir'd into `root`).
  def target_path
    File.join(Dir.pwd, "sig/errors.rbs")
  end

  context "when a directory sits at the target path" do
    before { FileUtils.mkdir_p(target_path) }

    it "--write reports it on one stderr line and exits 64" do
      status, _out, err = sig_gen("--write")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to eq("rigor sig-gen: cannot write #{target_path}: Is a directory\n")
    end

    it "writes nothing into the directory" do
      sig_gen("--write")

      expect(Dir.empty?(target_path)).to be(true)
    end
  end

  # `sig` itself being a regular file is the chmod-free stand-in for an unwritable parent: the
  # sig-root check's `realpath` fails ENOTDIR before a byte lands.
  context "when the sig root is a regular file" do
    before { write("sig", "not a directory\n") }

    it "--write reports the unwritable sig root on one stderr line and exits 64" do
      status, _out, err = sig_gen("--write")

      expect(status).to eq(Rigor::CLI::EXIT_USAGE)
      expect(err).to eq("rigor sig-gen: cannot write #{target_path}: Not a directory\n")
    end
  end
end
