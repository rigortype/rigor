# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

require "rigor/cli"
require "rigor/cli/sig_gen_command"

# #1150 / #1183 — under `--params=observed`, a `Data.define` / `Struct.new` member is typed from the construction
# sites the collector observes. The engine is unchanged: only sig-gen's proposal reads them. Each example runs the
# real CLI, so the collector's routing and the generator's member map are pinned together.
RSpec.describe Rigor::SigGen::MetaMemberObservation do
  let(:root) { Dir.mktmpdir }

  around { |example| Dir.chdir(root) { example.run } }

  after { FileUtils.remove_entry(root) }

  def write(relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def sig_gen(*argv)
    write(".rigor.yml", "paths:\n  - lib\nsignature_paths:\n  - sig\n") unless File.exist?(File.join(root,
                                                                                                     ".rigor.yml"))
    out = StringIO.new
    Rigor::CLI::SigGenCommand.new(argv: [*argv, "--config=#{File.join(root, '.rigor.yml')}"], out: out,
                                  err: StringIO.new).run
    out.string
  end

  def observed_print = sig_gen("--print", "--params=observed", "--observe=test")

  def rows(out, class_name)
    out[/^class #{Regexp.escape(class_name)} <.*?^end/m].to_s.lines.map(&:strip).grep(/\Adef /)
  end

  def define(source, test)
    write("lib/shapes.rb", source)
    write("test/shapes_test.rb", test)
  end

  # Row 1: keyword construction; literals widen to their class.
  it "types Data members from a keyword construction, widening the literals" do
    define("P = Data.define(:name, :age)\n", "P.new(name: \"a\", age: 1)\n")

    expect(rows(observed_print, "P")).to include("def name: () -> String", "def age: () -> Integer")
  end

  # Row 2: positional `.new` and `.[]` read through the same member-index map as keywords.
  it "maps a positional `.new` construction by member index" do
    define("A = Data.define(:name, :age)\n", "A.new(\"a\", 1)\n")

    expect(rows(observed_print, "A")).to include("def name: () -> String", "def age: () -> Integer")
  end

  it "reads a `.[]` construction like `.new`" do
    define("B = Data.define(:name, :age)\n", "B[\"a\", 1]\n")

    expect(rows(observed_print, "B")).to include("def name: () -> String", "def age: () -> Integer")
  end

  # Row 3.
  it "unions the types different construction sites pass" do
    define("Q = Data.define(:x)\n", "Q.new(x: \"a\")\nQ.new(x: nil)\n")

    expect(rows(observed_print, "Q")).to include("def x: () -> (String | nil)")
  end

  # Row 4: both class shapes, rows on the value class rather than the enclosing namespace.
  it "types the named-subclass and the block form, on the value class itself" do
    define(<<~RUBY, "N.new(x: 1)\nOuter::D.new(x: :k)\n")
      class N < Data.define(:x); end
      module Outer
        D = Data.define(:x) do
          def hi = 1
        end
      end
    RUBY

    out = observed_print
    expect(rows(out, "N")).to include("def x: () -> Integer")
    expect(rows(out, "Outer::D")).to include("def x: () -> Symbol")
  end

  # Row 5: reader and writer carry one T, positional and keyword_init alike.
  it "types a positional Struct's reader and writer with the same type" do
    define("S = Struct.new(:a, :b)\n", "S.new(1, \"z\")\n")

    expect(rows(observed_print, "S")).to include(
      "def a: () -> Integer", "def a=: (Integer) -> Integer", "def b: () -> String", "def b=: (String) -> String"
    )
  end

  it "types a keyword_init Struct from its keyword construction" do
    define("K = Struct.new(:a, keyword_init: true)\n", "K.new(a: :sym)\n")

    expect(rows(observed_print, "K")).to include("def a: () -> Symbol", "def a=: (Symbol) -> Symbol")
  end

  # A Struct fills a member the construction leaves out with nil; a Data construction cannot leave one out.
  it "adds nil for a Struct member a construction leaves out" do
    define("T = Struct.new(:a, :b)\nT2 = Struct.new(:a, :b)\n",
           "T.new(1)\nT.new(1, \"z\")\nT2.new(a: 1, b: \"z\")\nT2.new(a: 2)\n")

    out = observed_print
    expect(rows(out, "T")).to include("def b: () -> (String | nil)")
    expect(rows(out, "T2")).to include("def b: () -> (String | nil)")
  end

  it "reads nothing from a Data construction whose arity is not the member count" do
    define("W = Data.define(:a, :b)\n", "W.new(1)\n")

    expect(rows(observed_print, "W")).to include("def a: () -> untyped")
  end

  # Row 6: a splat site contributes nothing; the member uses the other sites, or stays untyped without one.
  it "reads nothing from a splat or double-splat construction" do
    define("U = Data.define(:m)\nU2 = Data.define(:m)\n", <<~RUBY)
      def build(args, opts)
        U.new(*args)
        U.new(**opts)
        U2.new(*args)
        U2.new(m: "a")
      end
    RUBY

    out = observed_print
    expect(rows(out, "U")).to include("def m: () -> untyped")
    expect(rows(out, "U2")).to include("def m: () -> String")
  end

  # Row 7.
  it "leaves a member no construction reaches untyped" do
    define("V = Data.define(:a)\nV2 = Struct.new(:a)\n", "1\n")

    out = observed_print
    expect(rows(out, "V")).to include("def a: () -> untyped")
    expect(rows(out, "V2")).to include("def a: () -> untyped", "def a=: (untyped) -> untyped")
  end

  # Row 8: the collector reads every file under the observe roots; a `Const = Data.define` class defined in a
  # source file resolves there, and a construction in an unobserved source file is not read.
  it "observes a construction in another observed file, and not one outside the observe roots" do
    write("lib/shapes.rb", "module M\n  X = Data.define(:a)\nend\n")
    write("lib/maker.rb", "class Maker\n  def make = M::X.new(a: :lib)\nend\n")
    write("test/a_test.rb", "M::X.new(a: 1)\n")

    expect(rows(observed_print, "M::X")).to include("def a: () -> Integer")
  end

  # Row 9: with no --observe, the project's test roots are read, `spec/` included.
  it "observes a spec file under the default test roots" do
    write("lib/shapes.rb", "Y = Data.define(:a)\n")
    write("spec/shapes_spec.rb", "Y.new(a: 1.5)\n")

    expect(rows(sig_gen("--print", "--params=observed"), "Y")).to include("def a: () -> Float")
  end

  # Row 10: a Struct writer call and a Data `with` call set a member as well as a construction does.
  it "reads a Struct writer call and a Data `with` call" do
    define("SW = Struct.new(:a)\nDW = Data.define(:a, :b)\n", <<~RUBY)
      s = SW.new("x")
      s.a = 1.5
      d = DW.new(a: 1, b: 2)
      d.with(a: :k)
    RUBY

    out = observed_print
    expect(rows(out, "SW")).to include("def a: () -> (Float | String)")
    expect(rows(out, "DW")).to include("def a: () -> (Integer | Symbol)", "def b: () -> Integer")
  end

  # Row 11: an untyped argument keeps the member untyped; the other sites do not narrow it.
  it "keeps a member untyped when one site passes an untyped argument" do
    define("Z = Data.define(:a)\n", "def make(v) = Z.new(a: v)\nZ.new(a: \"a\")\n")

    expect(rows(observed_print, "Z")).to include("def a: () -> untyped")
  end

  # A class with its own `initialize` takes that method's arguments, which need not be the members.
  it "reads no member off a class that defines its own initialize" do
    define(<<~RUBY, "I.new(a: 1)\n")
      I = Data.define(:a, :b) do
        def initialize(a:, b: "d") = super
      end
    RUBY

    expect(rows(observed_print, "I")).to include("def a: () -> untyped")
  end

  it "keeps every member untyped without --params=observed" do
    define("P = Data.define(:name)\nS = Struct.new(:a)\n", "P.new(name: \"a\")\nS.new(1)\n")

    out = sig_gen("--print")
    expect(rows(out, "P")).to include("def name: () -> untyped")
    expect(rows(out, "S")).to include("def a: () -> untyped", "def a=: (untyped) -> untyped")
  end
end
