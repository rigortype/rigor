# frozen_string_literal: true

# Issue #2991 — a splatted `include(*MODS)` / `prepend(*MODS)`, or any other mixin call the walk cannot name the
# module of, means every name on the class's instance side may come from that module: `call.undefined-method` must
# not fire on the class, nor on a subclass at any depth. `Scope::ResolutionChain` marks such a chain
# (`unnamed_mixin?`), and the rule reads that mark. A mixin whose order alone is unknown (`self.include M1`,
# `include M1; prepend M1`, the `wildcard_mixin?` mark) names its module and must keep reporting. `sig/` declares every
# class so the rule runs. `Sup` defines a method of its own, so it is a project
# entry on its subclasses' chains, not an external one (#2094), which already stands down on another route. Every
# row's Ruby behaviour was witnessed on Ruby 4.0.5: each quiet call returns 1, and each reported call raises
# `NoMethodError`. The literal-include row is a must-still-fire guard.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a class whose instance-side chain holds a splatted mixin (#2991)" do
  let(:mods) do
    <<~RUBY
      module M1
        def m1 = 1
      end
      MODS = [M1]
    RUBY
  end
  let(:hierarchy_sig) { "class Sup\nend\nclass Sub < Sup\nend\nclass Sub2 < Sub\nend\n" }

  def undefined_messages(files, sig)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "types.rbs"), sig)
    files.each { |name, source| File.write(File.join("lib", name), source) }
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-wildcard-mixin-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not fire on the including class" do
    source = "#{mods}class Sup\n  include(*MODS)\n  def t = self.m1\nend\n"
    expect(undefined_messages({ "a.rb" => source }, "class Sup\nend\n")).to be_empty
  end

  it "does not fire on its subclass" do
    source = "#{mods}class Sup\n  include(*MODS)\n  def t = 1\nend\nclass Sub < Sup\n  def u = self.m1\nend\n"
    expect(undefined_messages({ "a.rb" => source }, hierarchy_sig)).to be_empty
  end

  it "does not fire on its sub-subclass" do
    source = "#{mods}class Sup\n  include(*MODS)\n  def t = 1\nend\n" \
             "class Sub < Sup\nend\nclass Sub2 < Sub\n  def v = self.m1\nend\n"
    expect(undefined_messages({ "a.rb" => source }, hierarchy_sig)).to be_empty
  end

  it "does not fire on a subclass declared in another file" do
    files = { "a.rb" => "#{mods}class Sup\n  include(*MODS)\n  def t = 1\nend\n",
              "b.rb" => "class Sub < Sup\n  def u = self.m1\nend\n" }
    expect(undefined_messages(files, hierarchy_sig)).to be_empty
  end

  it "does not fire on a subclass of a splatted prepend" do
    source = "#{mods}class Sup\n  prepend(*MODS)\n  def t = 1\nend\nclass Sub < Sup\n  def u = self.m1\nend\n"
    expect(undefined_messages({ "a.rb" => source }, hierarchy_sig)).to be_empty
  end

  it "still fires on a class whose includes are all literal" do
    source = "#{mods}class Lit\n  include M1\n  def w = self.m2\nend\n"
    expect(undefined_messages({ "a.rb" => source }, "class Lit\nend\n")).to eq(["undefined method `m2' for Lit"])
  end

  it "still fires on the class object of a splatted include, whose singleton side it leaves closed" do
    source = "#{mods}class Sup\n  include(*MODS)\n  def t = 1\nend\nclass Probe\n  def self.q = Sup.m1\nend\n"
    expect(undefined_messages({ "a.rb" => source }, "class Sup\nend\nclass Probe\nend\n"))
      .to eq(["undefined method `m1' for singleton(Sup)"])
  end

  # A guard, not a pin of this change: the singleton side was already open (`extends_answer?`), and the instance
  # side must stay closed.
  it "opens only the singleton side for a splatted extend" do
    source = <<~RUBY
      module E1
        def e1 = 1
      end
      EMODS = [E1]
      class Ext
        extend(*EMODS)
        def self.s = self.e1
        def x = self.e1
      end
    RUBY
    expect(undefined_messages({ "a.rb" => source }, "class Ext\nend\n")).to eq(["undefined method `e1' for Ext"])
  end

  describe "a mixin whose order alone is unknown" do
    it "still fires on a subclass of `self.include M1`" do
      source = "#{mods}class SI\n  self.include M1\n  def t = 1\nend\nclass SISub < SI\n  def u = self.m2\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class SI\nend\nclass SISub < SI\nend\n"))
        .to eq(["undefined method `m2' for SISub"])
    end

    it "still fires on `include M1; prepend M1`" do
      source = "#{mods}class IP\n  include M1\n  prepend M1\n  def w = self.m2\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class IP\nend\n")).to eq(["undefined method `m2' for IP"])
    end

    it "still fires beside an opaque `instance_exec` whose block prepends onto an Array" do
      source = "class AP\n  def go(o) = o.instance_exec { @a = []; @a.prepend(1) }\n  def w = self.m2\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class AP\nend\n")).to eq(["undefined method `m2' for AP"])
    end
  end

  describe "a mixin no name spells" do
    it "does not fire on a subclass of `include helper`" do
      source = "#{mods}class HS\n  def self.helper = M1\n  include helper\n  def t = 1\nend\n" \
               "class HSub < HS\n  def u = self.m1\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class HS\nend\nclass HSub < HS\nend\n")).to be_empty
    end

    it "does not fire on a subclass of `send(:include, *MODS)`" do
      source = "#{mods}class SS\n  send(:include, *MODS)\n  def t = 1\nend\nclass SSub < SS\n  def u = self.m1\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class SS\nend\nclass SSub < SS\nend\n")).to be_empty
    end

    # A guard, not a pin: a module that defines an `included` hook already opens its includers (`Relevance::HOOKS`).
    it "does not fire on a subclass of a class whose included hook runs `base.include`" do
      source = "#{mods}module H\n  def self.included(base) = base.include(M1)\nend\n" \
               "class HK\n  include H\n  def t = 1\nend\nclass HKSub < HK\n  def u = self.m1\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class HK\nend\nclass HKSub < HK\nend\n")).to be_empty
    end

    it "does not fire on a subclass of `include M1, h`, for a method only `h` provides" do
      source = "#{mods}module M2\n  def m2 = 1\nend\nclass O1\n  def self.h = M2\n  include M1, h\n  def t = 1\nend\n" \
               "class O1Sub < O1\n  def u = self.m2\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class O1\nend\nclass O1Sub < O1\nend\n")).to be_empty
    end

    it "does not fire on a subclass of a class whose method runs `k.class_eval { include M1 }`" do
      source = "#{mods}class O4\n  def self.go(k) = k.class_eval { include M1 }\n  def t = 1\nend\n" \
               "class O4Sub < O4\n  def u = self.m1\nend\nO4.go(O4)\n"
      expect(undefined_messages({ "a.rb" => source }, "class O4\nend\nclass O4Sub < O4\nend\n")).to be_empty
    end

    it "does not fire on a subclass of a class that extends a module whose extended hook runs `base.include`" do
      source = "#{mods}module EH\n  def self.extended(base) = base.include(M1)\nend\n" \
               "class EX\n  extend EH\n  def t = 1\nend\nclass EXSub < EX\n  def u = self.m1\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class EX\nend\nclass EXSub < EX\nend\n")).to be_empty
    end

    it "does not fire on a subclass of a class that extends a module whose `class << self` extended hook runs " \
       "`base.include`" do
      source = "#{mods}module SE\n  class << self\n    def extended(base) = base.include(M1)\n  end\nend\n" \
               "class SX\n  extend SE\n  def t = 1\nend\nclass SXSub < SX\n  def u = self.m1\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class SX\nend\nclass SXSub < SX\nend\n")).to be_empty
    end

    # A guard, not a pin: a module that defines an `included` hook already opens its includers (`Relevance::HOOKS`).
    it "does not fire on a subclass of a class whose `class << self` included hook runs `base.include`" do
      source = "#{mods}module SH\n  class << self\n    def included(base) = base.include(M1)\n  end\nend\n" \
               "class SK\n  include SH\n  def t = 1\nend\nclass SKSub < SK\n  def u = self.m1\nend\n"
      expect(undefined_messages({ "a.rb" => source }, "class SK\nend\nclass SKSub < SK\nend\n")).to be_empty
    end

    it "opens the receiver of `Other.include(*MODS)`, not the class it is written in" do
      source = "#{mods}class Other\n  def t = 1\nend\n" \
               "class Inc\n  Other.include(*MODS)\n  def t = 1\n  def v = self.m1\nend\n" \
               "class OSub < Other\n  def u = self.m1\nend\n"
      sig = "class Other\nend\nclass Inc\nend\nclass OSub < Other\nend\n"
      expect(undefined_messages({ "a.rb" => source }, sig)).to eq(["undefined method `m1' for Inc"])
    end
  end
end
