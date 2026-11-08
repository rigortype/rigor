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

  def write_project(concern, includer, calls)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    declared = [concern, includer].flat_map { |body| body.scan(/^\s*(class|module) ([\w:]+( < \w+)?)/) }.uniq
    File.write(File.join("sig", "types.rbs"), declared.map { |kind, name| "#{kind} #{name}\nend\n" }.join)
    File.write(File.join("lib", "concern.rb"), concern)
    File.write(File.join("lib", "includer.rb"), includer)
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

  BASE = "class Base\n  def self.bar = 1\n  def self.baz = 2\nend\n"

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
    def x_module = "module X\n  def bar = \"X\"\nend\n"

    it "answers the module an included block extends" do
      write_project("#{x_module}#{concern('Cx', "  included do\n    extend X\n  end\n")}",
                    "#{BASE}class K2 < Base\n  include Cx\nend\n", ["K2.bar.upcase", "K2.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    it "answers the module a self.included hook extends" do
      write_project("#{x_module}module Hx\n  def self.included(base) = base.extend(X)\nend\n",
                    "#{BASE}class K4 < Base\n  include Hx\nend\n", ["K4.bar.upcase", "K4.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    it "answers a block's extend and a class body's class << self include" do
      includer = "#{BASE}class K1 < Base\n  [1].each { extend X }\nend\n" \
                 "class K3 < Base\n  [1].each { class << self; include X; end }\nend\n"
      write_project(x_module, includer, ["K1.bar.upcase", "K3.bar.upcase", "K1.bar.zork", "K3.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""] * 2)
    end

    # Ruby runs a `self.prepended` hook, and a `prepended do … end` block, only for a prepend.
    it "does not read a prepended hook for an including class" do
      write_project("#{x_module}module Hp\n  def self.prepended(base) = base.extend(X)\nend\n",
                    "#{BASE}class Kp < Base\n  include Hp\nend\n", ["Kp.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end

    it "reads a prepended block for a prepending class" do
      write_project("#{x_module}#{concern('Cp', "  prepended do\n    extend X\n  end\n")}",
                    "#{BASE}class Kq < Base\n  prepend Cp\nend\n", ["Kq.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    # The block's extend may not run, or names a module no table can: the read declines rather than answering Base's.
    {
      "a hook's extend of a computed module" => "module Hu\n  def self.included(base) = base.extend(const_get(:X))\nend\n",
      "a hook's conditional extend" => "module Hu\n  def self.included(base)\n    base.extend(X) if base.name\n  end\nend\n",
      "a hook's send(:extend)" => "module Hu\n  def self.included(base) = base.send(:extend, X)\nend\n",
      "a hook's singleton_class.include" => "module Hu\n  def self.included(base) = base.singleton_class.include(X)\nend\n",
      "an included block's extend of a computed module" =>
        "module Hu\n  extend ActiveSupport::Concern\n  def own = 1\n  included do\n    extend(Object.const_get(:X))\n  end\nend\n"
    }.each do |label, hook|
      it "declines for #{label}" do
        write_project("#{x_module}#{hook}", "#{BASE}class Ku < Base\n  include Hu\nend\n",
                      ["Ku.bar.upcase", "Ku.baz.zork"])
        expect(undefined_messages).to be_empty
      end
    end
  end

  # The second comment's witness: `C.singleton_class.ancestors` is `[#<Class:C>, CM, Cw::ClassMethods, #<Class:Base>]`.
  it "orders an included block's extend ahead of the concern's ClassMethods" do
    source = "module CM\n  def bar = \"CM\"\nend\n" \
             "#{concern('Cw',
                        "  included do\n    extend CM\n  end\n  class_methods do\n    def baz = \"baz\"\n  end\n")}"
    write_project(source, "#{BASE}class C < Base\n  include Cw\nend\n",
                  ["C.bar.upcase", "C.baz.upcase", "C.bar.zork", "C.baz.zork"])
    expect(undefined_messages).to eq(["undefined method `zork' for \"CM\"", "undefined method `zork' for \"baz\""])
  end

  # The tables keep `extend` and `include` statements apart, so a class with both has two orders for them: the read
  # stands where both give one answer, and declines where they differ.
  describe "a class that also extends a module of its own" do
    let(:source) do
      "module Own\n  def bar = \"own\"\nend\n#{concern('Co',
                                                       "  class_methods do\n    def bar = :cm\n    def baz = :cm\n  end\n")}"
    end

    # Ruby answers "own" for the first includer and :cm for the second.
    it "declines a name both blocks define, in either statement order" do
      includer = "#{BASE}class Ko < Base\n  include Co\n  extend Own\nend\n" \
                 "class Kr < Base\n  extend Own\n  include Co\nend\n"
      write_project(source, includer, ["Ko.bar.zork", "Kr.bar.zork"])
      expect(undefined_messages).to be_empty
    end

    it "answers a name only one block defines" do
      write_project(source, "#{BASE}class Ko < Base\n  include Co\n  extend Own\nend\n", ["Ko.baz.zork"])
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
      source = "module CM\n  def bar = 1\nend\n#{BASE}" \
               "#{concern('Cw', "  included do\n    extend CM\n  end\n  class_methods do\n    def baz = 2\n  end\n")}" \
               "class C < Base\n  include Cw\nend\n"
      expect(chain_names(source, "C")).to eq(%w[C CM Cw::ClassMethods Base])
    end

    # `Concern#append_features` records a concern included into another concern as a dependency and extends
    # nothing; the final includer's dependency read is #2992.
    it "does not extend a concern that includes a concern" do
      source = "#{concern('Cd', "  class_methods do\n    def build = 1\n  end\n")}" \
               "#{concern('Od', "  include Cd\n")}module Pd\n  include Cd\nend\n"
      expect(chain_names(source, "Od")).to eq(%w[Od ActiveSupport::Concern])
      expect(chain_names(source, "Pd")).to eq(%w[Pd Cd::ClassMethods])
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
