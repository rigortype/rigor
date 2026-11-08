# frozen_string_literal: true

# Issue #2901 — the computed definers #2897 (#2793) left unread: a class macro whose body runs `define_method` under
# a computed name, `Other.define_method(m)`, `send(:define_method, m)`, a computed `define_singleton_method`, and
# `attr_accessor(*NAMES)`. Each opens, to `call.undefined-method`, only the class and side it provably defines on;
# every shape has a same-file and a cross-file row. Each row's Ruby behaviour was witnessed on Ruby 4.0.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Computed definers and call.undefined-method (#2901)" do
  def write_project(source, calls, extra_files: {})
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    classes = ([source] + extra_files.values).flat_map { |body| body.scan(/^class (\w+)/).flatten }.uniq
    File.write(File.join("sig", "types.rbs"), classes.map { |name| "class #{name}\nend\n" }.join)
    File.write(File.join("lib", "defs.rb"), source)
    extra_files.each { |name, body| File.write(File.join("lib", name), body) }
    File.write(File.join("lib", "caller.rb"), "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  around do |example|
    Dir.mktmpdir("rigor-computed-definers-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def macro = "def self.my_attr(*n) = n.each { |x| define_method(x) { x } }"

  describe "a class macro whose body runs a computed define_method" do
    it "opens the instance side of the class whose body calls it, and not the class object" do
      write_project("class Mac\n  #{macro}\n  my_attr :foo\nend\n", %w[Mac.new.foo Mac.foo])
      expect(undefined_messages).to eq(["undefined method `foo' for singleton(Mac)"])
    end

    it "opens a subclass of the calling class" do
      write_project("class Mac\n  #{macro}\n  my_attr :foo\nend\nclass MacChild < Mac\nend\n", %w[MacChild.new.foo])
      expect(undefined_messages).to be_empty
    end

    it "opens a class calling a macro its superclass defines in another file" do
      write_project("class MUse < MBase\n  my_attr :bar\nend\n", %w[MUse.new.bar],
                    extra_files: { "base.rb" => "class MBase\n  #{macro}\nend\n" })
      expect(undefined_messages).to be_empty
    end

    it "opens a class calling a macro an extended module defines in another file" do
      macros = "module Macros\n  #{macro.sub('self.', '')}\nend\n"
      write_project("class Ext\n  extend Macros\n  my_attr :e\nend\n", %w[Ext.new.e],
                    extra_files: { "macros.rb" => macros })
      expect(undefined_messages).to be_empty
    end

    it "reads a macro defined in a class << self body, with its define_method under an if" do
      source = "class Sing\n  class << self\n    def my_attr(*n)\n      " \
               "n.each { |x| define_method(x) { x } if x }\n    end\n  end\n  my_attr :s\nend\n"
      write_project(source, %w[Sing.new.s])
      expect(undefined_messages).to be_empty
    end

    it "does not open a class whose own macro of the same name, in a sibling file, defines nothing" do
      write_project("class Mac\n  #{macro}\n  my_attr :foo\nend\n", %w[Sib.new.sib],
                    extra_files: { "sib.rb" => "class Sib\n  def self.my_attr(*n) = n\n  my_attr :sib\nend\n" })
      expect(undefined_messages).to eq(["undefined method `sib' for Sib"])
    end

    it "does not open a class that defines the macro without calling it in its body" do
      write_project("class Idle\n  #{macro}\n  def go = self.class\nend\n", %w[Idle.new.i])
      expect(undefined_messages).to eq(["undefined method `i' for Idle"])
    end

    it "does not read a define_method in a block that rebinds self, or in an instance method" do
      source = "class Fac\n  def self.my_attr(*n) = Class.new { n.each { |x| define_method(x) { x } } }\n  " \
               "my_attr :f\nend\n" \
               "class InDef\n  def go(m) = define_method(m) { m }\nend\n"
      write_project(source, %w[Fac.new.f InDef.new.g])
      expect(undefined_messages).to eq(["undefined method `f' for Fac", "undefined method `g' for InDef"])
    end

    it "does not read a define_method in a define_method block, which runs on an instance" do
      source = "class Wrap\n  def self.my_attr(*n) = define_method(:wrap) { n.each { |x| define_method(x) { x } } }\n" \
               "  my_attr :w\nend\n"
      write_project(source, %w[Wrap.new.w])
      expect(undefined_messages).to eq(["undefined method `w' for Wrap"])
    end

    it "does not read a define_method on another receiver, in another receiver's class_eval, or in a nested def" do
      source = "class Helper\nend\n" \
               "class Recv\n  def self.my_attr(*n) = n.each { |x| Helper.define_method(x) { x } }\n  my_attr :r\nend\n" \
               "class Ev\n  def self.my_attr(*n) = Helper.class_eval { n.each { |x| define_method(x) { x } } }\n" \
               "  my_attr :v\nend\n" \
               "class NestDef\n  def self.my_attr(*n)\n    def helper(x) = define_method(x) { x }\n  end\n" \
               "  my_attr :nd\nend\n"
      write_project(source, %w[Recv.new.r Ev.new.v NestDef.new.nd])
      expect(undefined_messages).to eq(["undefined method `nd' for NestDef", "undefined method `r' for Recv",
                                        "undefined method `v' for Ev"].sort)
    end

    it "does not read a macro written as another object's singleton method" do
      source = "class Other3\nend\nclass Host3\n  def self.my_attr(*n) = n\n" \
               "  def Other3.my_attr(*n) = n.each { |x| define_method(x) { x } }\n  my_attr :h\nend\n"
      write_project(source, %w[Host3.new.h])
      expect(undefined_messages).to eq(["undefined method `h' for Host3"])
    end
  end

  describe "define_method on a constant receiver" do
    it "opens that constant's class, and not the enclosing one" do
      write_project("class Other\nend\nclass Host\n  m = :x\n  Other.define_method(m) { 1 }\nend\n",
                    %w[Other.new.x Host.new.x])
      expect(undefined_messages).to eq(["undefined method `x' for Host"])
    end

    it "opens the constant's class declared in another file" do
      write_project("class Host2\n  m = :y\n  Other2.define_method(m) { 1 }\nend\n", %w[Other2.new.y],
                    extra_files: { "other.rb" => "class Other2\nend\n" })
      expect(undefined_messages).to be_empty
    end

    it "opens nothing for a receiver that is not a constant, even one that may be self" do
      source = "class Helper\nend\nclass Maybe\n  m = :mb\n  target = rand > 0.5 ? self : Helper\n  " \
               "target.define_method(m) { 1 }\nend\n"
      write_project(source, %w[Maybe.new.mb])
      expect(undefined_messages).to eq(["undefined method `mb' for Maybe"])
    end
  end

  describe "send(:define_method, m)" do
    it "opens the instance side of the class, and not the class object" do
      write_project("class Snd\n  m = :s\n  send(:define_method, m) { 1 }\nend\n", %w[Snd.new.s Snd.s])
      expect(undefined_messages).to eq(["undefined method `s' for singleton(Snd)"])
    end

    it "opens the class when another file reopens it with the call" do
      write_project("class Snd2\nend\n", %w[Snd2.new.t],
                    extra_files: { "reopen.rb" => "class Snd2\n  m = :t\n  send(:define_method, m) { 1 }\nend\n" })
      expect(undefined_messages).to be_empty
    end
  end

  describe "define_singleton_method with a computed name" do
    it "opens the class object, and not its instances" do
      write_project("class Dsm\n  m = :d\n  define_singleton_method(m) { 1 }\nend\n", %w[Dsm.d Dsm.new.d])
      expect(undefined_messages).to eq(["undefined method `d' for Dsm"])
    end

    it "opens the class object when another file reopens it with the call" do
      write_project("class Dsm2\nend\n", %w[Dsm2.e],
                    extra_files: { "reopen.rb" => "class Dsm2\n  m = :e\n  define_singleton_method(m) { 1 }\nend\n" })
      expect(undefined_messages).to be_empty
    end

    it "opens nothing from a class << self body, where it defines on the singleton's own singleton" do
      write_project("class Dsm3\n  class << self\n    m = :q\n    define_singleton_method(m) { 1 }\n  end\nend\n",
                    %w[Dsm3.q])
      expect(undefined_messages).to eq(["undefined method `q' for singleton(Dsm3)"])
    end
  end

  describe "attr_accessor with splatted names" do
    it "opens the instance side of the class, and not the class object" do
      write_project("class Atr\n  NAMES = %i[aa bb].freeze\n  attr_accessor(*NAMES)\nend\n", %w[Atr.new.aa Atr.aa])
      expect(undefined_messages).to eq(["undefined method `aa' for singleton(Atr)"])
    end

    it "opens the class when another file reopens it with the call" do
      write_project("class Atr2\nend\n", %w[Atr2.new.cc],
                    extra_files: { "reopen.rb" => "class Atr2\n  NAMES = %i[cc].freeze\n  attr_reader(*NAMES)\nend\n" })
      expect(undefined_messages).to be_empty
    end

    it "opens the singleton side alone from a class << self body" do
      write_project("class Atr3\n  class << self\n    attr_accessor(*%i[dd])\n  end\nend\n", %w[Atr3.dd Atr3.new.dd])
      expect(undefined_messages).to eq(["undefined method `dd' for Atr3"])
    end
  end

  # Guard: the walk's placement files a Class.new body under its own class, which keeps the enclosing class closed.
  it "does not open the enclosing class for a computed definer in a Class.new body" do
    write_project("class Outer\n  K = Class.new { attr_accessor(*%i[k]) }\nend\n", %w[Outer.new.k])
    expect(undefined_messages).to eq(["undefined method `k' for Outer"])
  end

  it "keeps reporting an unknown name on a class with a macro that defines nothing" do
    write_project("class Closed\n  def self.my_attr(*n) = n\n  my_attr :c\nend\n", %w[Closed.new.c])
    expect(undefined_messages).to eq(["undefined method `c' for Closed"])
  end
end
