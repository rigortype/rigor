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

  # Row 6: a splat site may write any member (`Sp.new(*["s"]).a == "s"`), so it keeps every member untyped even
  # beside a typed site.
  it "keeps every member untyped beside a splat construction" do
    define("U = Data.define(:m)\n", "U.new(*[\"s\"])\nU.new(m: 1)\n")

    expect(rows(observed_print, "U")).to include("def m: () -> untyped")
  end

  it "keeps every member untyped beside a double-splat construction" do
    define("U = Data.define(:m)\n", "def build(opts) = U.new(**opts)\nU.new(m: 1)\n")

    expect(rows(observed_print, "U")).to include("def m: () -> untyped")
  end

  # Row 7.
  it "leaves a member no construction reaches untyped (guard)" do
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

  # A class with its own `initialize` takes that method's arguments, which need not be the members. The override is
  # looked for across the source tree and the observed files, not only in the file defining the class.
  it "reads no member off a class that defines its own initialize" do
    define(<<~RUBY, "I.new(a: 1)\n")
      I = Data.define(:a, :b) do
        def initialize(a:, b: "d") = super
      end
    RUBY

    expect(rows(observed_print, "I")).to include("def a: () -> untyped")
  end

  it "keeps every member untyped without --params=observed (guard)" do
    define("P = Data.define(:name)\nS = Struct.new(:a)\n", "P.new(name: \"a\")\nS.new(1)\n")

    out = sig_gen("--print")
    expect(rows(out, "P")).to include("def name: () -> untyped")
    expect(rows(out, "S")).to include("def a: () -> untyped", "def a=: (untyped) -> untyped")
  end

  def expect_untyped(source_files, test, class_name, member = "a")
    source_files.each { |path, body| write(path, body) }
    write("test/shapes_test.rb", test)

    expect(rows(observed_print, class_name)).to include("def #{member}: () -> untyped")
  end

  # Ruby: `Coerce.new("1").x == 1.0` once another file reopens the class with its own `initialize`.
  it "reads no member off a class reopened with an initialize in another file" do
    expect_untyped({ "lib/shapes.rb" => "Coerce = Data.define(:a)\n",
                     "lib/coerce.rb" => "class Coerce\n  def initialize(a:) = super(a: Float(a))\nend\n" },
                   "Coerce.new(a: \"1\")\n", "Coerce")
  end

  # Ruby: a prepended `initialize` runs before the member assignment (`Pp.new(1).a == "1"`).
  it "reads no member off a class whose block prepends a module" do
    expect_untyped({ "lib/shapes.rb" => "module Mod\nend\nPp = Struct.new(:a) do\n  prepend Mod\nend\n" },
                   "Pp.new(1)\n", "Pp")
  end

  it "reads no member off a class a module is prepended to from another file" do
    expect_untyped({ "lib/shapes.rb" => "module Mod\nend\nPq = Struct.new(:a)\n",
                     "lib/patch.rb" => "Pq.prepend(Mod)\n" }, "Pq.new(1)\n", "Pq")
  end

  it "reads no member off a class that includes a project module defining initialize" do
    source = <<~RUBY
      module Init
        def initialize(*args) = super(*args.map(&:to_s))
      end
      Inc = Struct.new(:a) do
        include Init
      end
      Plain = Struct.new(:a) do
        include Comparable
      end
    RUBY
    expect_untyped({ "lib/shapes.rb" => source }, "Inc.new(1)\nPlain.new(1)\n", "Inc")
    expect(rows(observed_print, "Plain")).to include("def a: () -> Integer")
  end

  it "reads no member off a class that extends a project module defining new" do
    source = "module Maker\n  def new(*args) = super(*args.map(&:to_s))\nend\nEx = Struct.new(:a) do\n  extend Maker\nend\n"
    expect_untyped({ "lib/shapes.rb" => source }, "Ex.new(1)\n", "Ex")
  end

  it "reads no member off a class that define_methods initialize" do
    source = "Dm = Struct.new(:a) do\n  define_method(:initialize) { |a| super(a.to_s) }\nend\n"
    expect_untyped({ "lib/shapes.rb" => source }, "Dm.new(1)\n", "Dm")
  end

  it "reads no member off a class that aliases a method to initialize" do
    source = "Al = Struct.new(:a) do\n  def setup(a) = super(a.to_s)\n  alias initialize setup\nend\n"
    expect_untyped({ "lib/shapes.rb" => source }, "Al.new(1)\n", "Al")
  end

  # Ruby: `Sn.new(1).a == "1"` with `class << self; alias_method :orig_new, :new; def new(x) = orig_new(x.to_s)`.
  it "reads no member off a class whose singleton class overrides new" do
    source = "Sn = Struct.new(:a) do\n  class << self\n    def new(x) = super(x.to_s)\n  end\nend\n"
    expect_untyped({ "lib/shapes.rb" => source }, "Sn.new(1)\n", "Sn")
  end

  it "reads no member off a class whose singleton class aliases new" do
    source = "Sa = Struct.new(:a) do\n  class << self\n    alias_method :orig_new, :new\n  end\nend\n"
    expect_untyped({ "lib/shapes.rb" => source }, "Sa.new(1)\n", "Sa")
  end

  it "reads no member off a class whose singleton class aliases new with the alias keyword" do
    source = "Sk = Struct.new(:a) do\n  class << self\n    alias orig_new new\n  end\nend\n"
    expect_untyped({ "lib/shapes.rb" => source }, "Sk.new(1)\n", "Sk")
  end

  it "reads no member off a class with a def self.new" do
    source = "Ds = Struct.new(:a) do\n  def self.new(x) = super(x.to_s)\nend\n"
    expect_untyped({ "lib/shapes.rb" => source }, "Ds.new(1)\n", "Ds")
  end

  # Ruby: `Sub.new("str").a` is a String, and a `Base` reference may hold a `Sub`.
  it "reads no member off a class that has a subclass" do
    expect_untyped({ "lib/shapes.rb" => "Base = Struct.new(:a)\nclass Sub < Base; end\n" },
                   "Base.new(1)\nSub.new(\"str\")\n", "Base")
  end

  # S2. Ruby: `Struct.new(:a, :b, keyword_init: false).new(a: 1).a == { a: 1 }`, while an absent `keyword_init:`
  # takes the keywords as members on Ruby 3.2 and later.
  it "keeps every member untyped for a keyword construction of a keyword_init: false Struct" do
    expect_untyped({ "lib/shapes.rb" => "Kf = Struct.new(:a, :b, keyword_init: false)\n" },
                   "Kf.new(a: 1)\nKf.new(1, 2)\n", "Kf")
  end

  it "keeps every member untyped for a keyword construction of a Struct whose keyword_init: is not a literal" do
    expect_untyped({ "lib/shapes.rb" => "FLAG = false\nKd = Struct.new(:a, keyword_init: FLAG)\n" },
                   "Kd.new(a: 1)\n", "Kd")
  end

  it "maps a keyword construction of a Struct with no keyword_init:" do
    define("Ka = Struct.new(:a, :b)\n", "Ka.new(a: 1, b: \"x\")\n")

    expect(rows(observed_print, "Ka")).to include("def a: () -> Integer", "def b: () -> String")
  end

  # Ruby: a positional construction of a `keyword_init: true` Struct raises ArgumentError, so it stores nothing.
  it "reads nothing from a positional construction of a keyword_init: true Struct" do
    define("Kt = Struct.new(:a, keyword_init: true)\n", "Kt.new(a: :s)\nKt.new(1)\n")

    expect(rows(observed_print, "Kt")).to include("def a: () -> Symbol")
  end

  # M1. Ruby: `Mx.new(1, b: 2).b == { b: 2 }`.
  it "keeps every member untyped beside a construction mixing positionals and keywords" do
    expect_untyped({ "lib/shapes.rb" => "Mx = Struct.new(:a, :b)\n" }, "Mx.new(1, b: 2)\nMx.new(1, \"x\")\n",
                   "Mx", "b")
  end

  it "leaves a Struct member only ever left out untyped, not nil" do
    define("Om = Struct.new(:a, :b)\n", "Om.new(1)\n")

    expect(rows(observed_print, "Om")).to include("def a: () -> Integer", "def b: () -> untyped")
  end

  # S3. Writes whose value or member the collector does not map keep the member untyped.
  it "keeps the member an index write with a literal key names untyped" do
    define("Ix = Struct.new(:a, :b)\n", "s = Ix.new(\"x\", 1)\ns[:a] = 1.5\n")

    expect(rows(observed_print, "Ix")).to include("def a: () -> untyped", "def b: () -> Integer")
  end

  it "keeps every member untyped beside an index write with a computed key" do
    expect_untyped({ "lib/shapes.rb" => "Iy = Struct.new(:a)\n" },
                   "s = Iy.new(\"x\")\ns.members.each { |k| s[k] = 1.5 }\n", "Iy")
  end

  it "keeps the member a send of its writer names untyped" do
    expect_untyped({ "lib/shapes.rb" => "Se = Struct.new(:a)\n" }, "s = Se.new(\"x\")\ns.send(:a=, 1.5)\n", "Se")
  end

  it "keeps the member a public_send of its writer names untyped" do
    expect_untyped({ "lib/shapes.rb" => "Ps = Struct.new(:a)\n" },
                   "s = Ps.new(\"x\")\ns.public_send(:a=, 1.5)\n", "Ps")
  end

  it "keeps the member an operator write names untyped" do
    expect_untyped({ "lib/shapes.rb" => "Op = Struct.new(:a)\n" }, "o = Op.new(1)\no.a += 2.5\n", "Op")
  end

  it "keeps the member an or-write names untyped" do
    expect_untyped({ "lib/shapes.rb" => "Ow = Struct.new(:a)\n" }, "o = Ow.new(1)\no.a ||= :x\n", "Ow")
  end

  it "keeps the members a multiple assignment writes untyped" do
    expect_untyped({ "lib/shapes.rb" => "Ma = Struct.new(:a, :b)\n" }, "m = Ma.new(1, 2)\nm.a, m.b = \"m\", nil\n",
                   "Ma", "b")
  end

  it "keeps the member an index operator write names untyped" do
    expect_untyped({ "lib/shapes.rb" => "Io = Struct.new(:a)\n" }, "s = Io.new(1)\ns[:a] += 2.5\n", "Io")
  end
end
