# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #2437 — the skipped-class warning tells a superclass the project declares in source, but this run wrote nothing
# for, apart from one no source or RBS declares: only the second is fixed by providing a gem's RBS.
RSpec.describe Rigor::CLI::SigGenCommand do
  let(:root) { Dir.mktmpdir }

  around { |example| Dir.chdir(root) { example.run } }

  before { write(".rigor.yml", "paths:\n  - lib\n") }

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def sig_gen_err
    err = StringIO.new
    described_class.new(argv: ["--write", "lib", "--config=#{File.join(root, '.rigor.yml')}"], out: StringIO.new,
                        err: err).run
    err.string
  end

  it "advises typing or declaring a project superclass whose methods were all skipped" do
    write("lib/base.rb", "module Lib\n  class Base\n    def name = 1\n  end\nend\n")
    write("lib/text_base.rb", "module Lib\n  class TextBase < Base\n    def render(x) = x.whatever\n  end\nend\n")
    write("lib/cdata.rb", "module Lib\n  class Cdata < TextBase\n    def tag = 1\n  end\nend\n")

    err = sig_gen_err

    expect(err).to include("superclass this run wrote no signature for", "  Lib::Cdata < Lib::TextBase\n")
    expect(err).not_to include("rbs collection install")
  end

  it "advises the same for a project superclass whose own chain ends at a core class" do
    write("lib/errors.rb", "class AppError < StandardError\n  def render(x) = x.whatever\nend\n")
    write("lib/not_found.rb", "class NotFound < AppError\n  def code = 404\nend\n")

    err = sig_gen_err

    expect(err).to include("superclass this run wrote no signature for", "  NotFound < AppError\n")
    expect(err).not_to include("rbs collection install")
  end

  it "keeps the provide-RBS advice for a superclass nothing declares" do
    write("lib/sub.rb", "class Sub < Missing\n  def x = 1\nend\n")

    err = sig_gen_err

    expect(err).to include("superclass no loaded RBS declares", "rbs collection install", "  Sub < Missing\n")
    expect(err).not_to include("wrote no signature for")
  end

  # The first unwritten link is a project class, but writing it would not help: its own superclass is a gem's,
  # with no RBS. The line names the gem class, the one whose RBS is missing.
  it "keeps the provide-RBS advice for a project superclass whose own chain leaves the project" do
    write("lib/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\nend\n")
    write("lib/post.rb", "class Post < ApplicationRecord\n  def x = 1\nend\n")
    write("lib/mid.rb", "class Mid < Missing\n  def m(x) = x.whatever\nend\nclass Leaf < Mid\n  def l = 1\nend\n")

    err = sig_gen_err

    expect(err).to include("superclass no loaded RBS declares", "  Post < ActiveRecord::Base\n", "  Leaf < Missing\n")
    expect(err).not_to include("wrote no signature for")
  end

  # A `Data.define` constant declares its class without a `class` keyword. Its member readers are always typed, so
  # it goes unwritten here only because its `sig/` file does not parse.
  it "advises typing or declaring a project superclass declared by `Data.define`" do
    write("lib/rec.rb", "Rec = Data.define(:x)\n")
    write("sig/rec.rbs", "class Rec\n  def y: () ->\nend\n")
    write("lib/sub.rb", "class Sub < Rec\n  def s = 1\nend\n")

    err = sig_gen_err

    expect(err).to include("superclass this run wrote no signature for", "  Sub < Rec\n")
  end

  # #2461 — only `--write` and `--check` ask the writer whether it accepts a target, so the modes diverge on a
  # refused one: `--print` and JSON keep the subclass, `--write` and `--check` demote it.
  describe "a superclass shell on a `sig/` file that does not parse" do
    before do
      write("lib/errors.rb", "module Lib\n  class Error < StandardError; end\n  class Thing\n    def x = 1\n  end\nend\n")
      write("sig/errors.rbs", "module Lib\n  class Thing\n    def y: () ->\n  end\nend\n")
      write("lib/sub.rb", "module Lib\n  class NotFound < Error\n    def code = 404\n  end\nend\n")
    end

    def sig_gen_run(*argv)
      out = StringIO.new
      err = StringIO.new
      status = described_class.new(argv: [*argv, "lib", "--config=#{File.join(root, '.rigor.yml')}"], out: out,
                                   err: err).run
      [status, out.string, err.string]
    end

    it "still prints the subclass in --print" do
      _status, out, err = sig_gen_run("--print")

      expect(out).to include("class Lib::NotFound < ::Lib::Error")
      expect(err).not_to include("Lib::NotFound < Lib::Error")
    end

    it "still emits the subclass in --format=json" do
      _status, out, = sig_gen_run("--format=json")
      code = JSON.parse(out).fetch("candidates").find { |row| row["method"] == "code" }

      expect(code).to include("class" => "Lib::NotFound", "classification" => "new_method")
    end

    it "demotes the subclass in --check as --write does" do
      _status, _out, check_err = sig_gen_run("--check")
      _status, _out, write_err = sig_gen_run("--write")

      expect(check_err).to include("  Lib::NotFound < Lib::Error\n")
      expect(write_err).to include("  Lib::NotFound < Lib::Error\n")
      expect(File).not_to exist(File.join(root, "sig/sub.rbs"))
    end
  end

  # #2461 review — print and JSON runs ask no writer where a file would go, so where they are run from does not
  # change what they report. From a subdirectory, or from outside the project with `--config`, every target the
  # writer maps lies outside that directory's `sig/`.
  describe "print and JSON output from another working directory" do
    before do
      write("lib/base.rb", "class Base\n  def x = 1\nend\n")
      write("lib/sub.rb", "class Sub2 < Base\n  def y = 1\nend\n")
    end

    def sig_gen_from(dir, *argv)
      out = StringIO.new
      err = StringIO.new
      Dir.chdir(dir) do
        described_class.new(argv: [*argv, "--config=#{File.join(root, '.rigor.yml')}"], out: out, err: err).run
      end
      [out.string, err.string]
    end

    it "prints the same declarations from the root, a subdirectory and outside the project" do
      elsewhere = Dir.mktmpdir
      outputs = [root, File.join(root, "lib"), elsewhere].map { |dir| sig_gen_from(dir, "--print") }
      FileUtils.remove_entry(elsewhere)

      expect(outputs.first.first).to include("class Sub2 < ::Base")
      expect(outputs).to all(eq(outputs.first))
    end

    it "classifies the same candidates in JSON from the root, a subdirectory and outside the project" do
      elsewhere = Dir.mktmpdir
      rows = [root, File.join(root, "lib"), elsewhere].map do |dir|
        JSON.parse(sig_gen_from(dir, "--format=json").first).fetch("candidates")
            .map { |row| row.values_at("class", "method", "classification", "skip_reason") }
      end
      FileUtils.remove_entry(elsewhere)

      expect(rows.first).to include(["Sub2", "y", "new_method", nil])
      expect(rows).to all(eq(rows.first))
    end
  end
end
