# frozen_string_literal: true

require "fileutils"
require "json"
require "rbs"
require "rbs/cli"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #2436 — a class the loaded RBS declares generic is reopened with that declaration's type parameters when every
# one is plain, and its methods are skipped as `sig.skipped.generic-reopening` when one has a bound or a default.
# A header without the parameters fails `rbs validate` with `GenericParameterMismatchError`.
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

  def sig_gen(*argv)
    out = StringIO.new
    err = StringIO.new
    status = described_class.new(argv: [*argv, "--config=#{File.join(root, '.rigor.yml')}"], out: out, err: err).run
    [status, out.string, err.string]
  end

  def written(name)
    File.read(File.join(root, "sig/#{name}.rbs"))
  end

  # `rbs -I sig validate`, in process: its exit status and what it logged.
  def rbs_validate
    log = StringIO.new
    previous = RBS.logger_output
    RBS.logger_output = log
    RBS.instance_variable_set(:@logger, nil)
    status = RBS::CLI.new(stdout: StringIO.new, stderr: StringIO.new).run(["-I", File.join(root, "sig"), "validate"])
    [status, log.string]
  ensure
    RBS.logger_output = previous
    RBS.instance_variable_set(:@logger, nil)
  end

  describe "a core class reopened by the project" do
    before do
      write("lib/ext.rb", <<~RUBY)
        class Array
          def second_or_nil = 1
        end
        class Hash
          def to_liquid = "h"
        end
        class Set
          def to_liquid = 1
        end
        class String
          def shout = "S"
        end
        module Kernel
          def kfoo = 1
        end
      RUBY
    end

    it "copies the declaration's type parameters onto the header and leaves a non-generic class bare" do
      expect(sig_gen("--write", "lib").first).to eq(0)

      expect(written("ext")).to eq(<<~RBS)
        class Array[unchecked out E]
          def second_or_nil: () -> 1
        end

        class Hash[unchecked out K, unchecked out V]
          def to_liquid: () -> "h"
        end

        class Set[unchecked out A]
          def to_liquid: () -> 1
        end

        class String
          def shout: () -> "S"
        end

        module Kernel
          def kfoo: () -> 1
        end
      RBS
      expect(rbs_validate).to eq([0, ""])
    end

    it "prints the header it writes" do
      _status, out, = sig_gen("lib")

      expect(out.lines.grep(/\A(class|module) /).map(&:chomp)).to eq(
        ["class Array[unchecked out E]", "class Hash[unchecked out K, unchecked out V]",
         "class Set[unchecked out A]", "class String", "module Kernel"]
      )
    end
  end

  it "inserts the header with its parameters into a file that declares other classes" do
    write("sig/ext.rbs", "class String\n  def shout: () -> \"S\"\nend\n")
    write("lib/ext.rb", "class String\n  def shout = \"S\"\nend\nclass Array\n  def second_or_nil = 1\nend\n")

    expect(sig_gen("--write", "lib").first).to eq(0)

    expect(written("ext")).to end_with("class Array[unchecked out E]\n  def second_or_nil: () -> 1\nend\n")
    expect(rbs_validate).to eq([0, ""])
  end

  describe "a class the project's sig/ declares generic" do
    before do
      write("sig/box.rbs",
            "class Box[out T]\n  def get: () -> T\nend\n\nclass Bound[T < Comparable]\n  def get: () -> T\nend\n")
      write("lib/reopen.rb", <<~RUBY)
        class Box
          class Inner
            def x = 1
          end
        end
        class Bound
          class Inner
            def y = 1
          end
        end
      RUBY
    end

    it "opens a plain one with its parameters and skips the methods under a bounded one" do
      status, _out, err = sig_gen("--write", "lib")

      expect(status).to eq(0)
      expect(err).to include("sig.skipped.generic-reopening: 1")
      expect(written("reopen")).to eq("class Box[out T]\n  class Inner\n    def x: () -> 1\n  end\nend\n")
      expect(rbs_validate).to eq([0, ""])
    end

    it "names the skip in --format=json" do
      _status, out, = sig_gen("--format=json", "lib")
      row = JSON.parse(out).fetch("candidates").find { |r| r["method"] == "y" }

      expect(row).to include("classification" => "skipped", "skip_reason" => "sig.skipped.generic-reopening")
    end
  end
end
