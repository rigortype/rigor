# frozen_string_literal: true

# Issue #2884 — an explicit `def self.new` in a project or gem signature decides the type of `X.new`.
#
# `MethodDispatcher#meta_new` answers every `Singleton[X].new` before the RBS tier runs, and answered `Nominal[X]`
# once its curated lifts declined, so `class X; def self.new: () -> Y; end` still typed `X.new` as `X` and fired
# `call.undefined-method` on the `Y` it returns (`email_address` declares `def self.new: (...) -> Address`).
# `MethodDispatcher::DeclaredConstructor` now answers before that fallback, for a declaration outside the `rbs`
# gem's core and stdlib trees only: core's `Data.new: () -> bot`, `Ractor.new: … -> Ractor` and stdlib's
# `Tempfile.new` must not reach a project subclass.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a declared `def self.new` types `X.new` (#2884)" do
  def signature = <<~RBS
      class X
        def self.new: () -> Y
      end

      class Y
        def hello: () -> String
      end

      class W
        def self.new: () -> instance
      end

      class O
        def self.new: (String) -> Y | (Integer) -> O2
      end

      class O2
      end

      module EmailAddress
        def self.new: (?) -> Address

        class Address
          def normal: () -> String
        end
      end

      class Box[T]
        def self.new: [T] (T) -> Box[T]
        def self.make: [T] (T) -> Box[T]
      end

      class U
        def self.new: () -> untyped
      end

      class SigOnly
        def self.new: () -> Y
      end

    module SigMixin
      def helper: () -> Integer
    end

    class GemBase
      def initialize: (Integer) -> void
      def name: () -> Integer
    end

    class Gen[T]
      def initialize: (T) -> void
    end

    class Mix
      def self.new: (Integer) -> Mix | (String) -> Y
    end

    class Zed
    end

    module NewMixin
      def new: () -> Zed
    end

    module SourcedNewMixin
      def new: () -> Zed
    end
  RBS

  def run_check(lib, extra_sig = nil)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "x.rbs"), signature)
    File.write(File.join("sig", "extra.rbs"), extra_sig) if extra_sig
    lib.each { |name, source| File.write(File.join("lib", name), %(require "rigor/testing"\ninclude Rigor::Testing\n#{source})) }
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map { |d| d.message.delete_prefix("dump_type: ") }
  end

  def errors(result)
    result.diagnostics.reject { |d| d.qualified_rule == "dump.type" }.map(&:qualified_rule)
  end

  around do |example|
    Dir.mktmpdir("rigor-declared-new-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "answers the declared return, so a method of that class resolves (the issue's reproduction)" do
    result = run_check("t.rb" => <<~RUBY)
      class X; end
      class Y; def hello = "s"; end
      y = X.new
      dump_type(y)
      y.hello
    RUBY
    expect([dumps(result), errors(result)]).to eq([%w[Y], []])
  end

  it "answers the declaration from a signature file for a call in another lib file" do
    result = run_check("x.rb" => "class X; end\nclass Y; def hello = 's'; end\n",
                       "use.rb" => "dump_type(X.new.hello)\n")
    expect([dumps(result), errors(result)]).to eq([%w[String], []])
  end

  it "keeps `Nominal[X]` for a class that declares no `self.new` (control)" do
    expect(dumps(run_check("t.rb" => "class Plain; end\ndump_type(Plain.new)\n"))).to eq(%w[Plain])
  end

  it "answers the declaration a Ruby-source subclass inherits, as Ruby runs the inherited `self.new`" do
    expect(dumps(run_check("t.rb" => "class X; end\nclass Z < X; end\ndump_type(Z.new)\n"))).to eq(%w[Y])
  end

  it "reads `instance` as the receiver class, so a subclass inheriting `-> instance` gets the subclass" do
    expect(dumps(run_check("t.rb" => "class W; end\nclass V < W; end\ndump_type(W.new)\ndump_type(V.new)\n")))
      .to eq(%w[W V])
  end

  it "stops the walk at a source class that writes its own `def self.new`" do
    expect(dumps(run_check("t.rb" => <<~RUBY))).to eq(%w[Z])
      class X; end
      class Z < X
        def self.new = super
      end
      dump_type(Z.new)
    RUBY
  end

  it "stops the walk at an `extend`ed project module that defines `new`, which Ruby calls first" do
    expect(dumps(run_check("t.rb" => <<~RUBY))).to eq(%w[Z])
      class X; end
      module Maker
        def new = :made
      end
      class Z < X
        extend Maker
      end
      dump_type(Z.new)
    RUBY
  end

  it "answers the declaration of a superclass only a signature declares" do
    expect(dumps(run_check("t.rb" => "class Q < SigOnly; end\ndump_type(Q.new)\n"))).to eq(%w[Y])
  end

  it "passes an `extend`ed module that does not define `new`, RBS-known or external" do
    expect(dumps(run_check("t.rb" => <<~RUBY))).to eq(%w[Y Y])
      require "forwardable"
      class X; end
      module SigMixin
        def helper = 1
      end
      class Z1 < X
        extend Forwardable
      end
      class Z2 < X
        extend SigMixin
      end
      dump_type(Z1.new)
      dump_type(Z2.new)
    RUBY
  end

  it "stops at an `extend`ed module whose RBS declares `def new`, which Ruby runs ahead of the superclass's" do
    expect(dumps(run_check("t.rb" => <<~RUBY))).to eq(%w[Z1 Z2])
      class X; end
      module SourcedNewMixin; end
      class Z1 < X
        extend NewMixin
      end
      class Z2 < X
        extend SourcedNewMixin
      end
      dump_type(Z1.new)
      dump_type(Z2.new)
    RUBY
  end

  it "selects an overload by argument, and answers `Nominal[X]` when no overload takes the arguments" do
    expect(dumps(run_check("t.rb" => <<~RUBY))).to eq(%w[Y O2 O])
      class O; end
      dump_type(O.new("s"))
      dump_type(O.new(1))
      dump_type(O.new(:sym))
    RUBY
  end

  it "answers an untyped-parameter declaration on a module (the email_address gem shape)" do
    result = run_check("t.rb" => <<~RUBY)
      email = EmailAddress.new("a@example.com", host_validation: :syntax)
      dump_type(email)
      email.normal
    RUBY
    expect([dumps(result), errors(result)]).to eq([%w[EmailAddress::Address], []])
  end

  it "keeps `Nominal[X]` when the declared return is untyped" do
    expect(dumps(run_check("t.rb" => "class U; end\ndump_type(U.new)\n"))).to eq(%w[U])
  end

  it "binds a generic declaration's method type variable as any other singleton method does" do
    expect(dumps(run_check("t.rb" => "dump_type(Box.new(1))\ndump_type(Box.make(1))\n")))
      .to eq(["Box[1]", "Box[1]"])
  end

  it "answers `self.new` in a singleton method and `self.class.new` in an instance method the same way" do
    expect(dumps(run_check("t.rb" => <<~RUBY))).to eq(%w[Y Y])
      class X
        def self.make = dump_type(self.new)
        def remake = dump_type(self.class.new)
      end
    RUBY
  end

  it "re-points a return naming the declaring class to a subclass inheriting it, and keeps a foreign return" do
    expect(dumps(run_check("t.rb" => <<~RUBY))).to eq(%w[Box[1] SubBox Y])
      class SubBox < Box; end
      class X; end
      class Z < X; end
      dump_type(Box.new(1))
      dump_type(SubBox.new(1))
      dump_type(Z.new)
    RUBY
  end

  it "re-points the own-class overload of a declaration that also has a foreign one" do
    expect(dumps(run_check("t.rb" => <<~RUBY))).to eq(%w[SubMix Y])
      class Mix; end
      class SubMix < Mix; end
      dump_type(SubMix.new(1))
      dump_type(SubMix.new("s"))
    RUBY
  end

  describe "a `new` RBS builds from `initialize` is not a declaration" do
    it "keeps master's answers for the class, a Ruby subclass of it and a generic one" do
      result = run_check("t.rb" => <<~RUBY)
        class GemBase
          def initialize(x) = nil
          def name = 1
        end
        class MyThing < GemBase
          def name = "s"
        end
        class Gen
          def initialize(x) = nil
        end
        class SubGen < Gen; end
        dump_type(GemBase.new(1))
        dump_type(MyThing.new(1))
        dump_type(Gen.new(1))
        dump_type(SubGen.new(1))
        MyThing.new(1).name.upcase
      RUBY
      expect([dumps(result), errors(result)]).to eq([%w[GemBase MyThing Gen SubGen], []])
    end
  end

  it "declines where the singleton chain does not stand, as an unplaced `extend` across files leaves it" do
    result = run_check(
      "x.rb" => "class X; end\nmodule M1; end\nmodule M2; end\n",
      "z1.rb" => "class Z < X\n  extend M1\n  extend M2\nend\n",
      "z2.rb" => "class Z < X\n  extend M2\n  extend M1\nend\n",
      "t.rb" => "dump_type(Z.new)\n"
    )
    expect(dumps(result)).to eq(%w[Z])
  end

  describe "an inherited declaration answers the same whether or not an unrelated departing one is loaded" do
    def dumps_with(sig, source)
      FileUtils.rm_rf(%w[lib sig])
      FileUtils.mkdir_p("lib")
      FileUtils.mkdir_p("sig")
      File.write(File.join("sig", "x.rbs"), sig)
      File.write(File.join("lib", "t.rb"), %(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
      )
      dumps(guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]))
    end

    let(:unrelated) { "class Unrelated\n  def self.new: () -> Integer\nend\n" }

    it "answers the class object for an inherited `-> self`, which is not the instance" do
      sig = "class SelfRet\n  def self.new: () -> self\nend\n"
      source = "class SelfRet; end\nclass SR2 < SelfRet; end\ndump_type(SelfRet.new)\ndump_type(SR2.new)\n"
      expect([dumps_with(sig, source), dumps_with(sig + unrelated, source)])
        .to eq([%w[singleton(SelfRet) singleton(SR2)]] * 2)
    end

    it "compares the declaring class by full name, so `::Foo` from inside `A::Foo` is a foreign return" do
      sig = "module A\n  class Foo\n    def self.new: () -> ::Foo\n  end\nend\nclass Foo\nend\n"
      source = "module A; class Foo; end; end\nclass Foo; end\nclass Sub < A::Foo; end\ndump_type(Sub.new)\n"
      expect([dumps_with(sig, source), dumps_with(sig + unrelated, source)]).to eq([%w[Foo]] * 2)
    end
  end

  describe "a core or stdlib declaration is not inherited" do
    it "keeps a project subclass of a core class whose `self.new` names the core class" do
      expect(dumps(run_check("t.rb" => "class R < Ractor; end\ndump_type(R.new { 1 })\n"))).to eq(%w[R])
    end

    it "ignores a `self.new` a project signature adds to a core class by reopening it" do
      expect(dumps(run_check({ "t.rb" => "class MyStr < String; end\ndump_type(String.new)\ndump_type(MyStr.new)\n" },
                             "class String\n  def self.new: () -> Integer\nend\n")))
        .to eq(%w[String MyStr])
    end

    it "keeps a stdlib subclass, and leaves `Data.define` / `Struct.new` classes to their own tiers" do
      expect(dumps(run_check("t.rb" => <<~RUBY))).to eq(["T", "P(x: 1)", "S(a: 1)"])
        require "tempfile"
        class T < Tempfile; end
        P = Data.define(:x)
        S = Struct.new(:a)
        dump_type(T.new("x"))
        dump_type(P.new(x: 1))
        dump_type(S.new(1))
      RUBY
    end
  end

  describe "the ADR-46 edges of the walk" do
    def ancestry_sources(lib, sig)
      FileUtils.mkdir_p("lib")
      FileUtils.mkdir_p("sig")
      File.write(File.join("sig", "x.rbs"), sig)
      lib.each { |name, source| File.write(File.join("lib", name), source) }
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
      )
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, record_dependencies: true)
      guarded_run(runner, %w[lib])
      record = runner.file_dependencies.find { |path, _| File.basename(path) == "caller.rb" }&.last
      record ? record.ancestry_sources.map { |path| File.basename(path) } : []
    end

    let(:departing) { "class X\n  def self.new: () -> Y\nend\nclass Y\nend\n" }

    it "files the walked chain when the declaration answers, so an edit to the subclass re-checks the call" do
      expect(ancestry_sources({ "model.rb" => "class X; end\nclass Z < X; end\n", "caller.rb" => "Z.new\n" },
                              departing)).to include("model.rb")
    end

    it "files the chain of a `Nominal[X]` answer too once some declaration could answer a subclass otherwise" do
      expect(ancestry_sources({ "model.rb" => "class Widget; end\n", "caller.rb" => "Widget.new\n" }, departing))
        .to include("model.rb")
    end

    it "walks and files nothing when every declaration answers the instance, as before this tier" do
      expect(ancestry_sources({ "model.rb" => "class Widget; end\n", "caller.rb" => "Widget.new\n" },
                              "class X\n  def self.new: () -> instance\nend\n"))
        .not_to include("model.rb")
    end
  end
end
