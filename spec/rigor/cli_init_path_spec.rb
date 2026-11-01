# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"

require "rigor/cli"

# #2562 — `rigor init --path` into a directory that does not exist (or cannot be written) reports one `rigor init:`
# line and exits 64, the usage code `--config=PATH` gives for a path it cannot use. The write used to escape as a raw
# Errno::ENOENT backtrace, which read as an internal crash.
RSpec.describe Rigor::CLI do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def run_init(path)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(["init", "--path=#{path}"], out: out, err: err).run
    [status, out.string, err.string]
  end

  it "reports the missing directory on one stderr line and exits 64 without a backtrace" do
    status, out, err = run_init("nodir/x.yml")

    expect(status).to eq(64)
    expect(err).to eq("rigor init: cannot write nodir/x.yml: No such file or directory\n")
    expect(err).not_to match(/Errno|\.rb:\d+|from /)
    expect(out).to be_empty
  end

  it "does not create the missing directory or the file" do
    run_init("nodir/x.yml")

    expect(File.exist?("nodir")).to be(false)
  end

  it "still writes the file when the directory exists" do
    FileUtils.mkdir_p("conf")

    status, out, = run_init("conf/x.yml")

    expect(status).to eq(0)
    expect(out).to include("Created conf/x.yml")
    expect(File.exist?("conf/x.yml")).to be(true)
  end
end
