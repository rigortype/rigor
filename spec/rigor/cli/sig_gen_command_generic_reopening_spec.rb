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
        module Enumerable
          def kbar = 1
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

        module Enumerable[unchecked out E]
          def kbar: () -> 1
        end
      RBS
      expect(rbs_validate).to eq([0, ""])
    end

    it "prints the header it writes" do
      _status, out, = sig_gen("lib")

      expect(out.lines.grep(/\A(class|module) /).map(&:chomp)).to eq(
        ["class Array[unchecked out E]", "class Hash[unchecked out K, unchecked out V]",
         "class Set[unchecked out A]", "class String", "module Kernel", "module Enumerable[unchecked out E]"]
      )
    end
  end

  it "keeps the parameters on a candidate the effect pass rebuilds" do
    write(".rigor.yml", "paths:\n  - lib\neffects: {}\n")
    write("lib/ext.rb", "class Array\n  def ok = 1\nend\n")

    expect(sig_gen("--write", "lib").first).to eq(0)

    expect(written("ext")).to start_with("class Array[unchecked out E]\n")
  end

  # Review of #2473: inside `class Array[unchecked out E]` a bare `E` is the type variable, so a member returning
  # the project's class `E` must spell it `::E`, or `[1].mk` reads as the element type.
  describe "a class named like a copied type parameter" do
    before do
      write("lib/ext.rb", <<~RUBY)
        class E
          def e = 1
        end
        class K
          def k = 1
        end
        class Array
          def mk = E.new
          def mks = [E.new]
        end
        class Hash
          def mk = K.new
        end
      RUBY
    end

    def check_diagnostics
      write("lib/use.rb", "class User\n  def a = [1].mk.e\n  def b = [1].mks.first.e\n  def h = { 1 => 2 }.mk.k\nend\n")
      out = StringIO.new
      Rigor::CLI.start(["check", "--no-cache", "--format=json", "--config=#{File.join(root, '.rigor.yml')}", "lib/use.rb"],
                       out: out, err: StringIO.new)
      JSON.parse(out.string).fetch("diagnostics").map { |d| d["message"] }
    end

    it "anchors the class so the member still names it" do
      expect(sig_gen("--write", "lib").first).to eq(0)

      expect(written("ext")).to include(
        "class Array[unchecked out E]\n  def mk: () -> ::E\n  def mks: () -> [::E]\nend\n",
        "class Hash[unchecked out K, unchecked out V]\n  def mk: () -> ::K\nend\n"
      )
      expect(rbs_validate).to eq([0, ""])
      expect(check_diagnostics).to eq([])
    end
  end

  # Guard: a method-level `[E]` binds its own `E`, which the class's copied parameter must not disturb. No line of
  # the fix fails it; it holds the inline-copied member's text against an anchoring pass that would rewrite it.
  it "leaves a method-level type parameter of an inline declaration as written" do
    require "rigor-rbs-inline"
    Rigor::Plugin.register(Rigor::Plugin::RbsInline) unless Rigor::Plugin.registered_for("rbs-inline")
    write(".rigor.yml", "paths:\n  - lib\nplugins:\n  - gem: rigor-rbs-inline\n    id: rbs-inline\n    " \
                        "config:\n      require_magic_comment: false\n")
    write("lib/ext.rb", "class Array\n  #: [E] (E) -> E\n  def idt(x) = x\nend\n")

    expect(sig_gen("--write", "lib").first).to eq(0)

    expect(written("ext")).to eq("class Array[unchecked out E]\n  def idt: [E] (E) -> E\nend\n")
    expect(rbs_validate).to eq([0, ""])
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

    it "writes a bounded one's own methods into the declaration sig/ carries" do
      write("lib/bound.rb", "class Bound\n  def z = 1\nend\n")

      expect(sig_gen("--write", "lib").first).to eq(0)

      expect(written("box")).to end_with("class Bound[T < Comparable]\n  def get: () -> T\n  def z: () -> 1\nend\n")
      expect(rbs_validate).to eq([0, ""])
    end

    it "names the skip in --format=json" do
      _status, out, = sig_gen("--format=json", "lib")
      row = JSON.parse(out).fetch("candidates").find { |r| r["method"] == "y" }

      expect(row).to include("classification" => "skipped", "skip_reason" => "sig.skipped.generic-reopening")
    end
  end
end
