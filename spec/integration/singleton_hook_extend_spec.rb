# frozen_string_literal: true

# Issue #1592 — a module a class includes may extend it through a hook: an ActiveSupport::Concern's `class_methods do …
# end` block or `module ClassMethods`, an `included do extend M end` block, or a `self.included(base) =
# base.extend(M)` hook. The class's singleton resolution chain now holds each such module where Ruby puts it, after
# the class object and ahead of its superclass's, so a class-side call answers with the module's method instead of
# reporting it undefined or answering the superclass's.
#
# Every row's Ruby behaviour was witnessed on Ruby 4.0.5 with activesupport 8.1.4 loaded (`require
# "active_support/concern"`, left out here since the walk reads syntax only). The concern sits in its own file, the
# includer in another and the calls in a third; `sig/` declares every class and module, empty, so RBS answers no call.
# A call `.zork` on a result reports the type the read gave it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "singleton-side mixins a hook adds (#1592)" do
  around do |example|
    Dir.mktmpdir("rigor-singleton-hook-extend-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # `extra` maps more `lib/` file names to their source; `sig` replaces the generated declarations.
  def write_project(concern, includer, calls, extra: {}, sig: nil)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    sources = [concern, includer, *extra.values]
    declared = sources.flat_map { |body| body.scan(/^\s*(class|module) ([\w:]+( < \w+)?)/) }.uniq
    sig ||= declared.map { |kind, name| "#{kind} #{name}\nend\n" }.join
    File.write(File.join("sig", "types.rbs"), sig)
    File.write(File.join("lib", "concern.rb"), concern)
    File.write(File.join("lib", "includer.rb"), includer)
    extra.each { |name, body| File.write(File.join("lib", name), body) }
    File.write(File.join("lib", "use.rb"), "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  def concern(name, body) = "module #{name}\n  extend ActiveSupport::Concern\n#{body}end\n"

  def base_class = "class Base\n  def self.bar = 1\n  def self.baz = 2\nend\n"

  describe "a concern's class methods on a sig-declared includer" do
    it "answers a class_methods block's def" do
      write_project(concern("Ct", "  class_methods do\n    def build = \"s\"\n  end\n"),
                    "class Kt\n  include Ct\nend\n", ["Kt.build.upcase", "Kt.build.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"s\""])
    end

    it "answers an explicit module ClassMethods" do
      body = "  def own = 1\n  module ClassMethods\n    def build = \"s\"\n  end\n"
      write_project(concern("Ce", body), "class Ke\n  include Ce\nend\n", ["Ke.build.upcase", "Ke.build.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"s\""])
    end

    it "answers a module a self.included hook extends the includer with" do
      source = "module Ch\n  module ClassMethods\n    def build = \"s\"\n  end\n  " \
               "def self.included(base) = base.extend(ClassMethods)\nend\n"
      write_project(source, "class Kh\n  include Ch\nend\n", ["Kh.build.upcase", "Kh.build.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"s\""])
    end

    it "answers through a superclass that includes the concern" do
      write_project(concern("Cs", "  class_methods do\n    def build = \"s\"\n  end\n"),
                    "class Ps\n  include Cs\nend\nclass Ks < Ps\nend\n", ["Ks.build.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"s\""])
    end

    it "still reports a class-side name no module or class provides" do
      write_project(concern("Cn", "  class_methods do\n    def build = \"s\"\n  end\n"),
                    "class Kn\n  include Cn\nend\n", ["Kn.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for singleton(Kn)"])
    end

    # Ruby raises NoMethodError: ClassMethods is on the class object's ancestry, not its instances'. The concern
    # defines a method of its own, as an empty concern opens its includer's instance side (#2094).
    it "still reports an instance-side call to a ClassMethods method" do
      body = "  def own = 1\n  module ClassMethods\n    def build = \"s\"\n  end\n"
      write_project(concern("Ci", body), "class Ki\n  include Ci\nend\n", ["Ki.new.build"])
      expect(undefined_messages).to eq(["undefined method `build' for Ki"])
    end

    it "still reports a call when the class_methods block defines nothing" do
      write_project(concern("Cz", "  def own = 1\n  class_methods do\n  end\n"),
                    "class Kz\n  include Cz\nend\n", ["Kz.build"])
      expect(undefined_messages).to eq(["undefined method `build' for singleton(Kz)"])
    end
  end

  describe "a hook's extend on a subclass of a Base with same-named class methods" do
    def x_module = "module X\n  def bar = \"X\"\nend\nmodule Y\n  def bar = \"Y\"\nend\n"

    it "answers the module an included block extends" do
      write_project("#{x_module}#{concern('Cx', "  included do\n    extend X\n  end\n")}",
                    "#{base_class}class K2 < Base\n  include Cx\nend\n", ["K2.bar.upcase", "K2.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    it "answers the module a self.included hook extends" do
      write_project("#{x_module}module Hx\n  def self.included(base) = base.extend(X)\nend\n",
                    "#{base_class}class K4 < Base\n  include Hx\nend\n", ["K4.bar.upcase", "K4.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    it "answers a block's extend and a class body's class << self include" do
      includer = "#{base_class}class K1 < Base\n  [1].each { extend X }\nend\n" \
                 "class K3 < Base\n  [1].each { class << self; include X; end }\nend\n"
      write_project(x_module, includer, ["K1.bar.upcase", "K3.bar.upcase", "K1.bar.zork", "K3.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""] * 2)
    end

    # Ruby answers "Y", the later extend. The tables keep no order between one hook's two modules, so a name both
    # define declines and one only the superclass defines still answers.
    it "declines a name two modules of one hook both define" do
      hook = "module Hy\n  def self.included(base)\n    base.extend(X)\n    base.extend(Y)\n  end\nend\n"
      write_project("#{x_module}#{hook}", "#{base_class}class Ky < Base\n  include Hy\nend\n",
                    ["Ky.bar.zork", "Ky.baz.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 2"])
    end

    # A `next` or `break` in a block, or a `return` in a lambda, leaves only that block: the extend still runs.
    {
      "a block's next" => "[1].each { |x| next if x }",
      "a lambda's return" => "f = -> { return 1 }"
    }.each do |label, guard|
      it "answers a hook's extend after #{label}" do
        hook = "module Hn\n  def self.included(base)\n    #{guard}\n    base.extend(X)\n  end\nend\n"
        write_project("#{x_module}#{hook}", "#{base_class}class Kn < Base\n  include Hn\nend\n", ["Kn.bar.zork"])
        expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
      end
    end

    # A `return` in a block leaves the hook itself.
    it "declines a hook's extend after a block's return" do
      hook = "module Hn\n  def self.included(base)\n    [1].each { |x| return if x }\n    base.extend(X)\n  end\nend\n"
      write_project("#{x_module}#{hook}", "#{base_class}class Kn < Base\n  include Hn\nend\n",
                    ["Kn.bar.upcase", "Kn.bar.even?"])
      expect(undefined_messages).to be_empty
    end

    # A `raise` guard leaves the extend placed: past it, the extend runs.
    it "answers a hook's extend after a raise guard" do
      hook = "module Hr\n  def self.included(base)\n    raise \"no\" unless base\n    base.extend(X)\n  end\nend\n"
      write_project("#{x_module}#{hook}", "#{base_class}class Kr < Base\n  include Hr\nend\n", ["Kr.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    # Ruby answers 1: the include names the nearer `Ac::Mc`, which RBS declares and the source does not, so the
    # top-level `Mc`'s hook never runs.
    it "does not read the hook of a farther module when a nearer one exists only in RBS" do
      source = "#{x_module}module Mc\n  def self.included(base) = base.extend(X)\nend\n"
      includer = "#{base_class}module Ac\n  class Kc < Base\n    include Mc\n  end\nend\n"
      sig = "module X\nend\nmodule Y\nend\nmodule Mc\nend\nclass Base\nend\nmodule Ac\n  module Mc\n  end\n  " \
            "class Kc < Base\n  end\nend\n"
      write_project(source, includer, ["Ac::Kc.bar.zork"], sig: sig)
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end

    # Ruby keeps whichever definition loaded last, which the tables cannot tell: the read declines.
    it "declines a hook a second file redefines" do
      write_project("#{x_module}module Me\n  def self.included(base) = base.extend(X)\nend\n",
                    "#{base_class}class Km < Base\n  include Me\nend\n", ["Km.bar.even?"],
                    extra: { "redefine.rb" => "module Me\n  def self.included(base) = nil\nend\n" })
      expect(undefined_messages).to be_empty
    end

    # Two copies of one definition, apart only in whitespace, leave one hook whichever loads last.
    it "answers a hook a second file repeats with other whitespace" do
      write_project("#{x_module}module Mw\n  def self.included(base) = base.extend(X)\nend\n",
                    "#{base_class}class Kmw < Base\n  include Mw\nend\n", ["Kmw.bar.zork"],
                    extra: { "repeat.rb" => "module Mw\n  def  self.included(base)  =  base.extend(X)\nend\n" })
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    # Ruby runs two files' includes in load order: the class's two concerns have no known order.
    it "declines when a class reopened in two files includes a concern in each" do
      two = "#{concern('Ca', "  class_methods do\n    def bar = :a\n  end\n")}" \
            "#{concern('Cb', "  class_methods do\n    def bar = :b\n  end\n")}"
      write_project(two, "#{base_class}class Kw < Base\n  include Ca\nend\n", ["Kw.bar.zork"],
                    extra: { "reopen.rb" => "class Kw\n  include Cb\nend\n" })
      expect(undefined_messages).to be_empty
    end

    # Ruby runs a `self.prepended` hook, and a `prepended do … end` block, only for a prepend.
    it "does not read a prepended hook for an including class" do
      write_project("#{x_module}module Hp\n  def self.prepended(base) = base.extend(X)\nend\n",
                    "#{base_class}class Kp < Base\n  include Hp\nend\n", ["Kp.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end

    it "reads a prepended block for a prepending class" do
      write_project("#{x_module}#{concern('Cp', "  prepended do\n    extend X\n  end\n")}",
                    "#{base_class}class Kq < Base\n  prepend Cp\nend\n", ["Kq.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    # The block's extend may not run, or names a module no table can: the read declines rather than answering either
    # Base's 1 or X's "X", so neither `upcase` nor `even?` reports, whichever Ruby runs. `baz`, which only Base
    # defines, declines too: the unnamed module may define it.
    {
      "a hook's extend of a computed module" =>
        "module Hu\n  def self.included(base) = base.extend(const_get(:X))\nend\n",
      "a hook's conditional extend" =>
        "module Hu\n  def self.included(base)\n    base.extend(X) if base.name\n  end\nend\n",
      "a hook's send(:extend)" => "module Hu\n  def self.included(base) = base.send(:extend, X)\nend\n",
      "a hook's singleton_class.include" =>
        "module Hu\n  def self.included(base) = base.singleton_class.include(X)\nend\n",
      "a hook's extend after an early return" =>
        "module Hu\n  def self.included(base)\n    return unless base < String\n    base.extend(X)\n  end\nend\n",
      "an included block's extend after an early next" =>
        "module Hu\n  extend ActiveSupport::Concern\n  def own = 1\n  included do\n    next unless false\n    " \
        "extend X\n  end\nend\n",
      "an included block's extend nested in a block" =>
        "module Hu\n  extend ActiveSupport::Concern\n  def own = 1\n  included do\n    [1].each { extend X }\n  " \
        "end\nend\n",
      "an included block's class << self include" =>
        "module Hu\n  extend ActiveSupport::Concern\n  def own = 1\n  included do\n    class << self\n      " \
        "include X\n    end\n  end\nend\n",
      "a hook's class_eval block on the includer" =>
        "module Hu\n  def self.included(base) = base.class_eval { extend X }\nend\n",
      "an included block's conditional extend" =>
        "module Hu\n  extend ActiveSupport::Concern\n  def own = 1\n  included do\n    extend X if name\n  end\nend\n",
      "an included block's extend of a computed module" =>
        "module Hu\n  extend ActiveSupport::Concern\n  def own = 1\n  included do\n    " \
        "extend(Object.const_get(:X))\n  end\nend\n"
    }.each do |label, hook|
      it "declines for #{label}" do
        write_project("#{x_module}#{hook}", "#{base_class}class Ku < Base\n  include Hu\nend\n",
                      ["Ku.bar.upcase", "Ku.bar.even?", "Ku.baz.zork"])
        expect(undefined_messages).to be_empty
      end
    end
  end

  # `Concern#prepend_features` prepends `ClassMethods` to the class object's singleton, ahead of its own `def self.`:
  # `Kp.singleton_class.ancestors` starts `[Cp::ClassMethods, #<Class:Kp>]`.
  it "puts a prepended concern's ClassMethods ahead of the class object" do
    write_project(concern("Cp", "  def own = 1\n  class_methods do\n    def foo = \"s\"\n  end\n"),
                  "class Kp\n  def self.foo = 1\n  prepend Cp\nend\n", ["Kp.foo.zork"])
    expect(undefined_messages).to eq(["undefined method `zork' for \"s\""])
  end

  # `Concern#prepend_features` prepends `ClassMethods` when the `prepend` runs, and `class << self; prepend` its module
  # when that statement runs: the later is nearer, and the tables keep the two apart. Ruby answers :y for the first
  # class and "s" for the second, and the read declines both, as it does when a second file holds the singleton prepend.
  describe "a prepended concern beside a singleton prepend of the class" do
    let(:source) do
      class_methods = "  def own = 1\n  class_methods do\n    def foo = \"s\"\n  end\n"
      "module Ypt\n  def foo = :y\nend\n#{concern('Cpt', class_methods)}"
    end

    it "declines in either statement order" do
      includer = "class Kpt\n  prepend Cpt\n  class << self\n    prepend Ypt\n  end\nend\n" \
                 "class Kpu\n  class << self\n    prepend Ypt\n  end\n  prepend Cpt\nend\n"
      write_project(source, includer, ["Kpt.foo.zork", "Kpu.foo.zork"])
      expect(undefined_messages).to be_empty
    end

    it "declines when another file holds the singleton prepend" do
      write_project(source, "class Kpt\n  prepend Cpt\nend\n", ["Kpt.foo.zork"],
                    extra: { "reopen.rb" => "class Kpt\n  class << self\n    prepend Ypt\n  end\nend\n" })
      expect(undefined_messages).to be_empty
    end
  end

  # A `class_methods` def's visibility is its block's, not the concern's own instance method of the same name.
  it "answers a public class_methods def beside a private instance method of the same name" do
    body = "  class_methods do\n    def helper = 1\n  end\n  private\n  def helper = 2\n"
    write_project(concern("Cic", body), "class Kic\n  include Cic\nend\n", ["Kic.helper.zork"])
    expect(undefined_messages).to eq(["undefined method `zork' for 1"])
  end

  # Ruby raises NoMethodError: `private` in the block makes `priv` a private method of the class object.
  # The read withholds, so the result is `Dynamic`.
  {
    "a class_methods block" => "  class_methods do\n    private\n    def priv = 2\n  end\n",
    "an explicit ClassMethods" => "  module ClassMethods\n    private\n    def priv = 2\n  end\n"
  }.each do |label, body|
    it "does not answer a private method of #{label}" do
      write_project(concern("Cv", "  def own = 1\n#{body}"), "class Kpv\n  include Cv\nend\n", ["Kpv.priv.zork"])
      expect(undefined_messages).to be_empty
    end
  end

  # The second comment's witness: `C.singleton_class.ancestors` is `[#<Class:C>, CM, Cw::ClassMethods, #<Class:Base>]`.
  it "orders an included block's extend ahead of the concern's ClassMethods" do
    source = "module CM\n  def bar = \"CM\"\nend\n" \
             "#{concern('Cw',
                        "  included do\n    extend CM\n  end\n  class_methods do\n    def baz = \"baz\"\n  end\n")}"
    write_project(source, "#{base_class}class C < Base\n  include Cw\nend\n",
                  ["C.bar.upcase", "C.baz.upcase", "C.bar.zork", "C.baz.zork"])
    expect(undefined_messages).to eq(["undefined method `zork' for \"CM\"", "undefined method `zork' for \"baz\""])
  end

  # Issue #2992 — each concern in its own file.
  it "answers a class-side call with a dependency concern's class method" do
    outer = concern("Od2", "  include Cd2\n  class_methods do\n    def other = :od\n  end\n")
    write_project(concern("Cd2", "  class_methods do\n    def build = \"s\"\n  end\n"), "class Kd2\n  include Od2\nend\n",
                  ["Kd2.build.upcase", "Kd2.build.zork", "Kd2.other.zork"], extra: { "outer.rb" => outer })
    expect(undefined_messages).to eq(["undefined method `zork' for \"s\"", "undefined method `zork' for :od"])
  end

  # `include Ca8; include Cb8` includes `Cb8` last, so its `ClassMethods` is nearer.
  it "orders two included dependencies as the outer concern includes them" do
    write_project(concern("Ca8", "  class_methods do\n    def bar = :a\n  end\n"), "class Kl8\n  include Ol8\nend\n",
                  ["Kl8.bar.zork"], extra: { "cb8.rb" => concern("Cb8", "  class_methods do\n    def bar = :b\n  end\n"),
                                             "ol8.rb" => concern("Ol8", "  include Ca8\n  include Cb8\n") })
    expect(undefined_messages).to eq(["undefined method `zork' for :b"])
  end

  # `Concern` puts a prepended dependency ahead of the included ones (Ruby answers :a), which the tables list the
  # other way, so the read declines.
  it "declines between dependencies when the outer concern prepends one" do
    write_project(concern("Ca9", "  class_methods do\n    def bar = :a\n  end\n"), "class Kl9\n  include Ol9\nend\n",
                  ["Kl9.bar.zork"], extra: { "cb9.rb" => concern("Cb9", "  class_methods do\n    def bar = :b\n  end\n"),
                                             "ol9.rb" => concern("Ol9", "  include Ca9\n  prepend Cb9\n") })
    expect(undefined_messages).to be_empty
  end

  # Two files of the outer concern add their dependencies in load order.
  it "declines between dependencies the outer concern includes in two files" do
    write_project(concern("Ca7", "  class_methods do\n    def bar = :a\n  end\n"), "class Kl7\n  include Ol7\nend\n",
                  ["Kl7.bar.zork"], extra: { "cb7.rb" => concern("Cb7", "  class_methods do\n    def bar = :b\n  end\n"),
                                             "ol7a.rb" => concern("Ol7", "  include Ca7\n"),
                                             "ol7b.rb" => concern("Ol7", "  include Cb7\n") })
    expect(undefined_messages).to be_empty
  end

  # The tables keep `extend` and `include` statements apart, so a class with both has two orders for them: the read
  # stands where both give one answer, and declines where they differ.
  describe "a class that also extends a module of its own" do
    let(:source) do
      class_methods = "  class_methods do\n    def bar = :cm\n    def baz = :cm\n  end\n"
      "module Own\n  def bar = \"own\"\nend\n#{concern('Co', class_methods)}"
    end

    # Ruby answers "own" for the first includer and :cm for the second.
    it "declines a name both blocks define, in either statement order" do
      includer = "#{base_class}class Ko < Base\n  include Co\n  extend Own\nend\n" \
                 "class Kr < Base\n  extend Own\n  include Co\nend\n"
      write_project(source, includer, ["Ko.bar.zork", "Kr.bar.zork"])
      expect(undefined_messages).to be_empty
    end

    it "answers a name only one block defines" do
      write_project(source, "#{base_class}class Ko < Base\n  include Co\n  extend Own\nend\n", ["Ko.baz.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for :cm"])
    end
  end

  # The chain itself, where no diagnostic tells the orders apart.
  describe "the singleton chain" do
    def chain_names(source, name)
      root = Prism.parse(source).value
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
      Rigor::Scope::ResolutionChain.for(scope, name, :singleton, :methods).entries.map { |entry| entry.name || entry.raw }
    end

    it "is Ruby's for the second comment's witness" do
      source = "module CM\n  def bar = 1\nend\n#{base_class}" \
               "#{concern('Cw', "  included do\n    extend CM\n  end\n  class_methods do\n    def baz = 2\n  end\n")}" \
               "class C < Base\n  include Cw\nend\n"
      expect(chain_names(source, "C")).to eq(%w[C CM Cw::ClassMethods Base])
    end

    # `Concern#append_features` records a concern included into another concern as a dependency and extends
    # nothing; the final includer reads the dependency (#2992, below).
    it "does not extend a concern that includes a concern" do
      source = "#{concern('Cd', "  class_methods do\n    def build = 1\n  end\n")}" \
               "#{concern('Od', "  include Cd\n")}module Pd\n  include Cd\nend\n"
      expect(chain_names(source, "Od")).to eq(%w[Od ActiveSupport::Concern])
      expect(chain_names(source, "Pd")).to eq(%w[Pd Cd::ClassMethods])
    end

    # Issue #2992 — `Od.append_features(K)` includes the dependency `Cd` into `K` first, so `Cd::ClassMethods` sits
    # behind `Od::ClassMethods`; on a prepend edge both are prepended to the class object, `Od`'s last.
    describe "a concern's dependency concern" do
      let(:concerns) do
        "#{concern('Cd', "  class_methods do\n    def build = 1\n  end\n")}" \
          "#{concern('Od', "  include Cd\n  class_methods do\n    def other = 2\n  end\n")}" \
          "#{concern('On', "  include Cd\n  def own = 1\n")}class Base\nend\n"
      end

      it "extends the final includer behind the outer concern's ClassMethods" do
        source = "#{concerns}class Ki < Base\n  include Od\nend\n"
        expect(chain_names(source, "Ki")).to eq(%w[Ki Od::ClassMethods Cd::ClassMethods Base])
      end

      it "prepends both to a class that prepends the outer concern" do
        source = "#{concerns}class Kp < Base\n  prepend Od\nend\n"
        expect(chain_names(source, "Kp")).to eq(%w[Od::ClassMethods Cd::ClassMethods Kp Base])
      end

      # Ruby's `On.const_get(:ClassMethods)` does not reach `Cd`, which is no ancestor of `On`.
      it "lists the dependency's ClassMethods once when the outer concern has none" do
        source = "#{concerns}class Kn < Base\n  include On\nend\n"
        expect(chain_names(source, "Kn")).to eq(%w[Kn Cd::ClassMethods Base])
      end
    end

    it "puts a later include's modules ahead of an earlier one's" do
      source = "module A1\n  def a = 1\nend\nmodule A2\n  def a = 2\nend\n" \
               "module H1\n  def self.included(base) = base.extend(A1)\nend\n" \
               "module H2\n  def self.included(base) = base.extend(A2)\nend\n" \
               "class Kh\n  include H1\n  include H2\nend\n"
      expect(chain_names(source, "Kh")).to eq(%w[Kh A2 A1])
    end
  end
end
