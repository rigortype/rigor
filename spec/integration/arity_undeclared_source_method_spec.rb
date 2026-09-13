# frozen_string_literal: true

# Issue #992 — `call.wrong-arity` against a method the project defines in Ruby source and declares nowhere,
# read off the `def`'s own parameter envelope (`Scope::DiscoveryIndex#discovered_parameter_envelopes`).
#
# The rule is a NEGATIVE one opened onto code that was never checked, so most of this file is declines.
# Every decline is written as a pair over the same fixture: the control without the trigger fires (so the
# fixture is not vacuous), and the same project with the trigger added stays silent.
require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "call.wrong-arity on a source-defined method with no declaration (#992)" do
  around do |example|
    Dir.mktmpdir("rigor-arity-undeclared-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write_files(files)
    files.each do |relative, contents|
      FileUtils.mkdir_p(File.dirname(relative))
      File.write(relative, contents)
    end
  end

  def configuration(extra = {})
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0).merge(extra))
  end

  # `[path, line, message]` for every `call.wrong-arity` the run reports.
  def arity(files, extra_config = {})
    write_files(files)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(extra_config), cache_store: nil)
    guarded_run(runner, %w[lib]).diagnostics
                                .select { |d| d.rule == "call.wrong-arity" }
                                .map { |d| [d.path.delete_prefix("lib/"), d.line, d.message] }
  end

  def messages(files, extra_config = {})
    arity(files, extra_config).map(&:last)
  end

  describe "the issue's repro" do
    it "fires on both call shapes, with the message shape the RBS path produces" do
      expect(arity("lib/a.rb" => <<~RUBY)).to eq(
        class A
          def f(num)
            num
          end
        end

        A.new.f
        A.new.f(1, 2)
        A.new.f(1)
      RUBY
        [["a.rb", 7, "wrong number of arguments to `f' on A (given 0, expected 1)"],
         ["a.rb", 8, "wrong number of arguments to `f' on A (given 2, expected 1)"]]
      )
    end

    it "reads optional, rest and post parameters into a min..max envelope" do
      expect(messages("lib/a.rb" => <<~RUBY)).to eq(
        class A
          def opt(a, b = 1) = a
          def rest(a, *r, z) = a
          def self.cls(x, y = 2) = x
        end

        A.new.opt
        A.new.opt(1, 2)
        A.new.opt(1, 2, 3)
        A.new.rest(1)
        A.new.rest(1, 2, 3, 4, 5)
        A.cls
        A.cls(1, 2, 3)
      RUBY
        ["wrong number of arguments to `opt' on A (given 0, expected 1..2)",
         "wrong number of arguments to `opt' on A (given 3, expected 1..2)",
         "wrong number of arguments to `rest' on A (given 1, expected 2..Infinity)",
         "wrong number of arguments to `cls' on A (given 0, expected 1..2)",
         "wrong number of arguments to `cls' on A (given 3, expected 1..2)"]
      )
    end

    it "fires across files, against a subclass that inherits the def, and on a class reopened with the same shape" do
      expect(arity(
               "lib/base.rb" => "class Base\n  def f(a) = a\nend\n",
               "lib/reopen.rb" => "class Base\n  def f(b) = b\nend\n",
               "lib/sub.rb" => "class Sub < Base\nend\n",
               "lib/use.rb" => "Base.new.f\nSub.new.f(1, 2)\n"
             )).to eq(
               [["use.rb", 1, "wrong number of arguments to `f' on Base (given 0, expected 1)"],
                ["use.rb", 2, "wrong number of arguments to `f' on Sub (given 2, expected 1)"]]
             )
    end
  end

  # `super`, `yield` and `&block` in a body do not change the def's own envelope, and a block-pass at the
  # call site is not a positional: `f(&blk)` against `def f(a)` raises ArgumentError at runtime too.
  describe "what stays in scope" do
    it "checks an override that calls super against the override's own envelope" do
      expect(messages("lib/a.rb" => <<~RUBY)).to eq(["wrong number of arguments to `f' on B (given 2, expected 1)"])
        class A
          def f(a, b) = [a, b]
        end

        class B < A
          def f(a)
            yield a if block_given?
            super(a, 1)
          end
        end

        B.new.f(1, 2)
        B.new.f(1) { |x| x }
      RUBY
    end

    it "counts a call with a block-pass by its positionals" do
      expect(messages("lib/a.rb" => <<~RUBY)).to eq(["wrong number of arguments to `f' on A (given 0, expected 1)"])
        class A
          def f(a) = a
        end

        A.new.f(&:to_s)
      RUBY
    end

    it "checks a class whose superclass the project does not declare, since the class's own def shadows it" do
      expect(messages("lib/a.rb" => <<~RUBY)).to eq(["wrong number of arguments to `f' on A (given 2, expected 1)"])
        class A < Some::Gem::Base
          def f(a) = a
        end

        A.new.f(1, 2)
      RUBY
    end

    it "checks a class whose own def shadows a SimpleDelegator's forwarding" do
      expected = ["wrong number of arguments to `f' on Wrapper (given 2, expected 1)"]
      expect(messages("lib/a.rb" => <<~RUBY)).to eq(expected)
        require "delegate"

        class Wrapper < SimpleDelegator
          def f(a) = a
        end

        Wrapper.new(Object.new).f(1, 2)
      RUBY
    end

    it "checks through a mixin RBS declares without the name" do
      expect(messages("lib/a.rb" => <<~RUBY)).to eq(["wrong number of arguments to `f' on A (given 2, expected 1)"])
        class A
          include Comparable

          def f(a) = a
        end

        A.new.f(1, 2)
      RUBY
    end
  end

  describe "declines" do
    def control
      <<~RUBY
        class A
          def f(a) = a
        end
      RUBY
    end

    let(:call) { "A.new.f(1, 2)\n" }

    it "(control) fires on the plain fixture every decline below extends" do
      expect(messages("lib/a.rb" => control + call))
        .to eq(["wrong number of arguments to `f' on A (given 2, expected 1)"])
    end

    it "when the name also comes from define_method" do
      expect(messages("lib/a.rb" => "#{control}class A\n  define_method(:f) { |a, b| a }\nend\n#{call}")).to eq([])
    end

    it "when a define_method's name is computed" do
      expect(messages("lib/a.rb" => "#{control}class A\n  %i[g].each { |n| define_method(n) { |*| } }\nend\n#{call}"))
        .to eq([])
    end

    it "when a singleton def is shadowed by define_singleton_method" do
      source = "class A\n  def self.s(x) = x\nend\n"
      expect(messages("lib/a.rb" => "#{source}A.s(1, 2)\n"))
        .to eq(["wrong number of arguments to `s' on A (given 2, expected 1)"])
      expect(messages("lib/a.rb" => "#{source}class A\n  define_singleton_method(:s) { |*a| a }\nend\nA.s(1, 2)\n"))
        .to eq([])
    end

    it "when the class defines method_missing" do
      hook = "class A\n  def method_missing(name, *args) = nil\nend\n"
      expect(messages("lib/a.rb" => "#{control}#{hook}#{call}")).to eq([])
    end

    it "when an ancestor defines respond_to_missing?" do
      source = <<~RUBY
        class Base
          def respond_to_missing?(name, include_private = false) = true
        end

        class A < Base
          def f(a) = a
        end
      RUBY
      expect(messages("lib/a.rb" => source + call)).to eq([])
    end

    it "when the class is reopened with a different arity in the same file" do
      expect(messages("lib/a.rb" => "#{control}class A\n  def f(a, b) = a\nend\n#{call}")).to eq([])
    end

    it "when the class is reopened with a different arity in another file" do
      expect(messages("lib/a.rb" => control + call, "lib/z.rb" => "class A\n  def f(a, b) = a\nend\n")).to eq([])
    end

    it "when a conditional defines the name twice" do
      source = "class A\n  if RUBY_VERSION > '3'\n    def f(a) = a\n  else\n    def f(a, b) = a\n  end\nend\n"
      expect(messages("lib/a.rb" => source + call)).to eq([])
    end

    it "when the name is an alias target" do
      expect(messages("lib/a.rb" => "#{control}class A\n  alias f_without_log f\nend\n#{call}")).to eq([])
    end

    it "when alias_method names the method" do
      expect(messages("lib/a.rb" => "#{control}class A\n  alias_method :g, :f\nend\n#{call}")).to eq([])
    end

    it "when a class-body macro names the method (memoize :f)" do
      expect(messages("lib/a.rb" => "#{control}class A\n  memoize :f\nend\n#{call}")).to eq([])
    end

    it "when a class-body macro wraps the def inline (memoize def f)" do
      expect(messages("lib/a.rb" => "class A\n  memoize def f(a) = a\nend\n#{call}")).to eq([])
    end

    it "when Forwardable delegates the name" do
      source = "require 'forwardable'\nclass A\n  extend Forwardable\n  def_delegators :@x, :f\nend\n"
      expect(messages("lib/a.rb" => control + source + call)).to eq([])
    end

    it "when the name is undefined" do
      expect(messages("lib/a.rb" => "#{control}class A\n  undef f\nend\n#{call}")).to eq([])
    end

    it "when a project subclass overrides the name with a different arity" do
      expect(messages("lib/a.rb" => control + call, "lib/b.rb" => "class B < A\n  def f(a, b) = a\nend\n")).to eq([])
    end

    it "when a project subclass defines method_missing-free but dynamic surface (class_eval)" do
      expect(messages("lib/a.rb" => control + call, "lib/b.rb" => "class B < A\n  class_eval 'def f(*) = 1'\nend\n"))
        .to eq([])
    end

    it "when an included project module defines the name with a different arity" do
      source = "module M\n  def f(a, b) = a\nend\nclass A\n  include M\nend\n"
      expect(messages("lib/a.rb" => control + source + call)).to eq([])
    end

    it "when a prepended project module defines the name with a different arity" do
      source = "module P\n  def f(*args) = super\nend\nclass A\n  prepend P\nend\n"
      expect(messages("lib/a.rb" => control + source + call)).to eq([])
    end

    it "when the class includes a module the project does not declare and RBS does not know" do
      expect(messages("lib/a.rb" => "#{control}class A\n  include Some::Gem::Mixin\nend\n#{call}")).to eq([])
    end

    it "when a mixin argument is not a constant" do
      expect(messages("lib/a.rb" => "#{control}class A\n  include Module.new\nend\n#{call}")).to eq([])
    end

    it "when the class is class_eval'd from outside" do
      expect(messages("lib/a.rb" => control + call,
                      "lib/patch.rb" => "A.class_eval do\n  def f(*) = 1\nend\n")).to eq([])
    end

    it "when a constant receiver includes a module from outside" do
      expect(messages("lib/a.rb" => control + call, "lib/patch.rb" => "A.include(Some::Gem::Mixin)\n")).to eq([])
    end

    # GitLab's `IntegrationsHelper.prepend_mod_with("IntegrationsHelper")` prepends a module from `ee/`,
    # which the survey's analysed paths do not reach.
    it "when a project mixin helper may prepend a module the analysis cannot see" do
      expect(messages("lib/a.rb" => "#{control}#{call}A.prepend_mod_with('A')\n")).to eq([])
      expect(messages("lib/a.rb" => "#{control}class A\n  include_mod_with 'A'\nend\n#{call}")).to eq([])
    end

    it "when a method body rewrites the class (class_eval in an inherited hook)" do
      hook = "class A\n  def self.inherited(sub)\n    sub.class_eval { define_method(:f) { |*| } }\n  end\nend\n"
      expect(messages("lib/a.rb" => "#{control}#{hook}#{call}")).to eq([])
    end

    it "when a method body extends some object with a module that defines the name" do
      decorator = "module Loud\n  def f(*args) = args\nend\nclass Decorate\n  def call(obj) = obj.extend(Loud)\nend\n"
      expect(messages("lib/a.rb" => "#{control}#{decorator}#{call}")).to eq([])
    end

    it "when a refinement redefines the name" do
      refinement = "module Loosen\n  refine A do\n    def f(*args) = args\n  end\nend\n"
      expect(messages("lib/a.rb" => "#{control}#{refinement}#{call}")).to eq([])
    end

    it "when a pre_eval: file patches the name (ADR-17)" do
      write_files("patches/a.rb" => "class A\n  def f(*args) = nil\nend\n")
      expect(messages({ "lib/a.rb" => control + call }, "pre_eval" => ["patches/a.rb"])).to eq([])
    end

    it "when a plugin declares the receiver's class open (ADR-26)" do
      plugin = Class.new(Rigor::Plugin::Base) do
        manifest(id: "open-a", version: "0.1.0", open_receivers: ["A"])
      end
      stub_const("OpenAPlugin", plugin)
      Rigor::Plugin.unregister!
      write_files("lib/a.rb" => control + call)
      runner = Rigor::Analysis::Runner.new(
        configuration: configuration("plugins" => ["rigor-open-a"]), cache_store: nil,
        plugin_requirer: ->(_name) { Rigor::Plugin.register(plugin) || true }
      )
      rules = guarded_run(runner, %w[lib]).diagnostics.map(&:rule)
      expect(rules).not_to include("call.wrong-arity")
    ensure
      Rigor::Plugin.unregister!
    end

    # The LSP `prebuilt:` runner seeds an empty project scope and runs no discovery pass, so a reopening in
    # another file is invisible to it; each file's own walk would see one `def` and nothing else.
    it "when no whole-project discovery pass seeded the scope" do
      write_files("lib/a.rb" => control + call, "lib/z.rb" => "class A\n  def f(a, b) = a\nend\n")
      scan = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil).prepare_project_scan
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, prebuilt: scan)
      expect(guarded_run(runner, %w[lib/a.rb]).diagnostics.map(&:rule)).not_to include("call.wrong-arity")
    end

    it "when the method is private" do
      expect(messages("lib/a.rb" => "class A\n  private\n\n  def f(a) = a\nend\n#{call}")).to eq([])
    end

    it "when the def takes a required keyword" do
      expect(messages("lib/a.rb" => "class A\n  def f(a, k:) = a\nend\nA.new.f(1, 2)\nA.new.f\n")).to eq([])
    end

    it "when the receiver's class is a bundled (core) class the project reopens" do
      source = "class String\n  def shout(a) = a\nend\n"
      expect(messages("lib/a.rb" => "#{source}'x'.shout(1, 2)\n")).to eq([])
    end

    # `.new` reaches `initialize` through `Class#new`, which records nothing under `[:singleton, :new]`; the
    # constructor's envelope is not read off `initialize`, so this stays out of the issue's scope.
    it "for a constructor, whose `initialize` is not read as `.new`" do
      expect(messages("lib/a.rb" => "class A\n  def initialize(a) = nil\nend\nA.new\nA.new(1, 2)\n")).to eq([])
    end

    describe "call-site shapes that are not statically countable" do
      {
        "a splat" => "args = []\nA.new.f(*args, 2)\n",
        "a double splat" => "opts = {}\nA.new.f(1, **opts)\n",
        "keyword arguments" => "A.new.f(1, k: 2)\n",
        "a `...` forward" => "def fwd(...) = A.new.f(1, ...)\n"
      }.each do |shape, source|
        it "declines #{shape}" do
          expect(messages("lib/a.rb" => control + source)).to eq([])
        end
      end
    end

    # Without the `parameter_inference:` gate `x` is untyped and nothing reaches the rule; with it, `x` is
    # seeded `A` from the call site, a lower bound the body must not conclude from.
    it "on an ADR-67 WD6b inferred-parameter receiver" do
      source = control + <<~RUBY
        class User
          def go = use(A.new)

          def use(x)
            x.f(1, 2)
          end
        end
      RUBY
      expect(messages({ "lib/a.rb" => source }, "parameter_inference" => true)).to eq([])
    end

    # `self` in a module's instance method is typed as the module, but it is an instance of an includer
    # that may define the name with any arity (#739's reasoning).
    it "on an instance of a project module" do
      source = "module M\n  def f(a) = a\n\n  def g = self.f(1, 2)\nend\n"
      expect(messages("lib/a.rb" => source)).to eq([])
      expect(messages("lib/a.rb" => source.sub("module M", "class M"))).to eq(
        ["wrong number of arguments to `f' on M (given 2, expected 1)"]
      )
    end

    it "on `self.class` inside a project module, which is the includer's class at runtime" do
      source = "module M\n  def self.build(a) = a\n\n  def g = self.class.build(1, 2)\nend\n"
      expect(messages("lib/a.rb" => source)).to eq([])
      expect(messages("lib/a.rb" => "#{source}M.build(1, 2)\n")).to eq(
        ["wrong number of arguments to `build' on M (given 2, expected 1)"]
      )
    end

    # tdiary's `PStore.new(path).transaction { … }` inside `module TDiary::IO`: `PStore` is the project's
    # `TDiary::IO::PStore` only when that file is loaded, and the stdlib `::PStore` otherwise.
    it "when the receiver's class shares its name with another class the call site's nesting can reach" do
      shadowing = <<~RUBY
        module App
          class Channel
            def self.select(channels) = channels
          end

          module Integration
            def poll = Channel.select
          end
        end
      RUBY
      expect(messages("lib/a.rb" => shadowing)).to eq(
        ["wrong number of arguments to `select' on App::Channel (given 0, expected 1)"]
      )
      expect(messages("lib/a.rb" => "class Channel
  def self.select(*) = nil
end
" + shadowing)).to eq([])
    end
  end
end
