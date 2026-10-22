# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"
require "rigor/cli/type_of_command"

# Issue #512 — `rigor type-of` built a bare single-file scope, so a class another project file declares read
# `Dynamic[top]` where `rigor check` resolves it to `singleton(User)`. The probe now folds the cross-file discovery
# tables from the bundles a prior `rigor check --incremental` left in the snapshot, and keeps the single-file scope
# when there is none (re-parsing the project for one probe cost twice the probe).
RSpec.describe "rigor type-of over a project (#512)" do
  around do |example|
    Dir.mktmpdir("rigor-type-of-project-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def warm_snapshot
    argv = ["--incremental", "--no-ci-detect", "--no-stats", "--no-baseline"]
    Rigor::CLI::CheckCommand.new(argv: argv, out: StringIO.new, err: StringIO.new).run
  end

  def type_of(position, *flags)
    out = StringIO.new
    err = StringIO.new
    status = Rigor::CLI::TypeOfCommand.new(argv: [*flags, position], out: out, err: err).run
    [status, out.string.lines.grep(/\Atype:/).first.to_s.sub("type:", "").strip, err.string]
  end

  before do
    write(".rigor.yml", "paths:\n  - lib\n")
    write("lib/user.rb", "class User\n  def self.current = 1\nend\n")
    write("lib/controller.rb", "User\nclass Local; end\nLocal\n")
  end

  context "with a warm incremental snapshot" do
    before { warm_snapshot }

    it "types a constant another project file declares as its singleton, as check does" do
      status, type, err = type_of("lib/controller.rb:1:1")

      expect(status).to eq(0)
      expect(err).to eq("")
      expect(type).to eq("singleton(User)")
    end

    it "keeps typing a constant the probed file declares itself (positive control)" do
      _status, type, = type_of("lib/controller.rb:3:1")

      expect(type).to eq("singleton(Local)")
    end

    it "re-walks a file edited since the snapshot, so a class added there resolves" do
      write("lib/user.rb", "class User\nend\nclass Account\nend\n")
      write("lib/controller.rb", "Account\n")

      _status, type, = type_of("lib/controller.rb:1:1")

      expect(type).to eq("singleton(Account)")
    end
  end

  # The editor buffer stands in for lib/user.rb: the seed must read the buffer's bytes, not the file's.
  context "with a warm snapshot and an editor buffer" do
    before do
      write("lib/c2.rb", "x = User.current\nx\n")
      warm_snapshot
      write("buf.rb", "class User\n  def self.current = \"s\"\nend\n")
    end

    it "folds the buffer's declarations in place of the file's" do
      _status, type, = type_of("lib/c2.rb:2:1", "--tmp-file", "buf.rb", "--instead-of", "lib/user.rb")

      expect(type).to eq('"s"')
    end

    it "matches the configured file when the buffer is named by an absolute path" do
      _status, type, = type_of("lib/c2.rb:2:1", "--tmp-file", "buf.rb", "--instead-of", File.expand_path("lib/user.rb"))

      expect(type).to eq('"s"')
    end

    it "answers from the file on disk without a buffer (control)" do
      _status, type, = type_of("lib/c2.rb:2:1")

      expect(type).to eq("1")
    end
  end

  context "without a snapshot" do
    it "keeps the single-file scope and says nothing on stderr" do
      status, type, err = type_of("lib/controller.rb:1:1")

      expect(status).to eq(0)
      expect(err).to eq("")
      expect(type).to eq("Dynamic[top]")
    end

    it "still types a same-file constant (positive control)" do
      _status, type, = type_of("lib/controller.rb:3:1")

      expect(type).to eq("singleton(Local)")
    end
  end
end
