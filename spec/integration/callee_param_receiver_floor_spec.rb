# frozen_string_literal: true

# Issue #2515 — a hand-off on a parameter or local receiver inside the callee (`def self.a(p, o, h) = h.c(p, o)`).
# A local every assignment of which is a constant or `Const.new` is typed inside the callee. Any other receiver
# resolves by name to the user instance defs of that name, each under its own class; more than eight floor the handed
# parameter outright, and a name no user def has hands off nothing.
require "spec_helper"

RSpec.describe "the callee floor follows a hand-off on a parameter or local receiver (#2515)", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }
  let(:writer) { 'parser.on("--format=FORMAT") { |value| options[:format] = value }' }
  let(:reader) { "puts(options.to_s)" }

  def program(defs, call)
    <<~RUBY
      #{defs}
      class Help
        def run(argv)
          options = { format: "text" }
          OptionParser.new { |opts| #{call} }.parse!(argv)
          if options[:format] == "json"
            puts "{}"
          else
            puts "text"
          end
        end
      end
    RUBY
  end

  def helper(body) = "class Helper\n  def c(parser, options) = #{body}\nend"

  def opts(body) = "class Opts\n  #{body}\nend"

  describe "a parameter receiver" do
    let(:entry) { "def self.a(parser, options, h) = h.c(parser, options)" }
    let(:call) { "Opts.a(opts, options, Helper.new)" }

    it "is silent when the same-named instance def writes" do
      expect(rules(program("#{helper(writer)}\n#{opts(entry)}", call))).to eq([])
    end

    it "keeps the literal when the instance def only reads" do
      expect(rules(program("#{helper(reader)}\n#{opts(entry)}", call))).to eq(always)
    end

    it "is silent through an instance entry method too" do
      defs = "#{helper(writer)}\n#{opts('def a(parser, options, h) = h.c(parser, options)')}"
      expect(rules(program(defs, "Opts.new.a(opts, options, Helper.new)"))).to eq([])
    end

    it "follows the def's own hand-offs under its class" do
      defs = "class Helper\n  def c(parser, options) = really(parser, options)\n  " \
             "def really(parser, options) = #{writer}\nend\n#{opts(entry)}"
      expect(rules(program(defs, call))).to eq([])
    end

    it "keeps the literal when no user def has the name" do
      defs = opts("def self.a(parser, options, h) = h.fetch(parser, options)")
      expect(rules(program(defs, call))).to eq(always)
    end

    it "reads a def in a module" do
      defs = "module Hm\n  def c(parser, options) = #{writer}\nend\n#{opts(entry)}"
      expect(rules(program(defs, "Opts.a(opts, options, Object.new)"))).to eq([])
    end
  end

  describe "a local receiver typed inside the callee" do
    it "from Const.new" do
      entry = "def self.a(parser, options)\n    h = Helper.new\n    h.c(parser, options)\n  end"
      expect(rules(program("#{helper(writer)}\n#{opts(entry)}", "Opts.a(opts, options)"))).to eq([])
    end

    it "from Const.new keeps the literal when that class only reads, whatever a same-named def elsewhere does" do
      entry = "def self.a(parser, options)\n    h = Helper.new\n    h.c(parser, options)\n  end"
      other = "class Other\n  def c(parser, options) = #{writer}\nend"
      defs = "#{helper(reader)}\n#{other}\n#{opts(entry)}"
      expect(rules(program(defs, "Opts.a(opts, options)"))).to eq(always)
    end

    it "from a constant" do
      help = "class Help2\n  def self.c(parser, options) = #{writer}\nend"
      entry = "def self.a(parser, options)\n    h = Help2\n    h.c(parser, options)\n  end"
      expect(rules(program("#{help}\n#{opts(entry)}", "Opts.a(opts, options)"))).to eq([])
    end

    it "from a constant keeps the literal when the class only reads" do
      help = "class Help2\n  def self.c(parser, options) = #{reader}\nend"
      entry = "def self.a(parser, options)\n    h = Help2\n    h.c(parser, options)\n  end"
      expect(rules(program("#{help}\n#{opts(entry)}", "Opts.a(opts, options)"))).to eq(always)
    end
  end

  describe "a local the callee cannot type" do
    let(:entry) do
      "def self.a(parser, options)\n    h = make\n    h.c(parser, options)\n  end\n  def self.make = Helper.new"
    end

    it "resolves by name" do
      expect(rules(program("#{helper(writer)}\n#{opts(entry)}", "Opts.a(opts, options)"))).to eq([])
    end

    it "keeps the literal when the same-named def only reads" do
      expect(rules(program("#{helper(reader)}\n#{opts(entry)}", "Opts.a(opts, options)"))).to eq(always)
    end

    it "resolves by name when one assignment is not a constant form" do
      entry = "def self.a(parser, options, flag)\n    h = Other.new\n    h = Helper.new if flag\n    " \
              "h = make unless flag\n    h.c(parser, options)\n  end\n  def self.make = Helper.new"
      other = "class Other\n  def c(parser, options) = #{reader}\nend"
      defs = "#{helper(writer)}\n#{other}\n#{opts(entry)}"
      expect(rules(program(defs, "Opts.a(opts, options, true)"))).to eq([])
    end

    it "resolves by name for a block-local receiver" do
      entry = "def self.a(parser, options, list) = list.each { |h| h.c(parser, options) }"
      expect(rules(program("#{helper(writer)}\n#{opts(entry)}", "Opts.a(opts, options, [Helper.new])"))).to eq([])
    end

    it "resolves by name for a block parameter that shadows a typed local" do
      entry = "def self.a(parser, options, list)\n    h = Other.new\n    " \
              "list.each { |h| h.c(parser, options) }\n    h\n  end"
      other = "class Other\n  def c(parser, options) = #{reader}\nend"
      defs = "#{helper(writer)}\n#{other}\n#{opts(entry)}"
      expect(rules(program(defs, "Opts.a(opts, options, [Helper.new])"))).to eq([])
    end

    it "resolves by name for a parameter the def also assigns a constant form" do
      entry = "def self.a(parser, options, h)\n    h = Other.new if options.empty?\n    h.c(parser, options)\n  end"
      other = "class Other\n  def c(parser, options) = #{reader}\nend"
      defs = "#{helper(writer)}\n#{other}\n#{opts(entry)}"
      expect(rules(program(defs, "Opts.a(opts, options, Helper.new)"))).to eq([])
    end

    it "resolves by name for an op-assigned local" do
      entry = "def self.a(parser, options)\n    h = Other.new\n    h ||= make\n    h.c(parser, options)\n  end\n  " \
              "def self.make = Helper.new"
      other = "class Other\n  def c(parser, options) = #{reader}\nend"
      defs = "#{helper(writer)}\n#{other}\n#{opts(entry)}"
      expect(rules(program(defs, "Opts.a(opts, options)"))).to eq([])
    end

    it "resolves by name for a local that is a multiple-assignment target" do
      entry = "def self.a(parser, options)\n    h = Other.new\n    h, _n = make, 1\n    " \
              "h.c(parser, options)\n  end\n  def self.make = Helper.new"
      other = "class Other\n  def c(parser, options) = #{reader}\nend"
      defs = "#{helper(writer)}\n#{other}\n#{opts(entry)}"
      expect(rules(program(defs, "Opts.a(opts, options)"))).to eq([])
    end
  end

  # The local's type is read from every assignment in the def, including the scopes the hand-off walk skips and the
  # spellings that rebind or extend it without a visible write. `Helper#c` reads and `Other#c` writes, so a local
  # that is still `Helper` keeps the literal and a local that may be anything resolves by name and is silent.
  describe "a local the callee may rebind or extend without a plain write" do
    let(:other) { "class Other\n  def c(parser, options) = #{writer}\nend" }
    let(:mixin) { "module Mut\n  def c(parser, options) = #{writer}\nend" }

    def with_body(body, extra: "")
      entry = "def self.a(parser, options)\n    h = Helper.new\n    #{body}\n    h.c(parser, options)\n  end"
      rules(program("#{helper(reader)}\n#{other}\n#{extra}\n#{opts(entry)}", "Opts.a(opts, options)"))
    end

    it "keeps the literal when nothing rebinds it (control)" do
      expect(with_body("nil")).to eq(always)
    end

    {
      "a lambda" => "re = -> { h = Other.new }\n    re.call",
      "an instance_exec block" => "Object.new.instance_exec { h = Other.new }",
      "a define_singleton_method block" => "define_singleton_method(:x) { h = Other.new }\n    x",
      "a nested block" => "[1].each { h = Other.new }",
      "binding.local_variable_set" => "binding.local_variable_set(:h, Other.new)",
      "eval" => 'eval("h = Other.new")'
    }.each do |label, body|
      it "resolves by name when #{label} writes it" do
        expect(with_body(body)).to eq([])
      end
    end

    it "resolves by name when a Kernel.binding is taken" do
      expect(with_body("Kernel.binding")).to eq([])
    end

    it "resolves by name when it is the receiver of send" do
      expect(with_body("h.send(:extend, Mut)", extra: mixin)).to eq([])
    end

    it "resolves by name when its singleton class is reached" do
      expect(with_body("h.singleton_class.include(Mut)", extra: mixin)).to eq([])
    end

    it "resolves by name when it is aliased to another local" do
      expect(with_body("g = h\n    g.extend(Mut)", extra: mixin)).to eq([])
    end

    it "resolves by name when it defines a singleton method" do
      expect(with_body("h.define_singleton_method(:c) { |parser, options| options.clear }")).to eq([])
    end

    it "resolves by name when it is extended" do
      expect(with_body("h.extend(Mut)", extra: mixin)).to eq([])
    end

    it "resolves by name when it gets a singleton def" do
      expect(with_body("def h.c(parser, options) = nil")).to eq([])
    end
  end

  # A def reached through the name is walked under its own class only when nothing can override what it calls.
  describe "an owner a project class may override" do
    let(:entry) { "def self.a(parser, options, h) = h.c(parser, options)" }
    let(:base) do
      "class Helper\n  def c(parser, options) = really(parser, options)\n  " \
        "def really(parser, options) = #{reader}\nend"
    end

    it "keeps the literal when no class overrides the callee's hand-off (control)" do
      expect(rules(program("#{base}\n#{opts(entry)}", "Opts.a(opts, options, Helper.new)"))).to eq(always)
    end

    it "floors a def whose class has a subclass that overrides the hand-off target" do
      sub = "class Sub < Helper\n  def really(parser, options) = #{writer}\nend"
      expect(rules(program("#{base}\n#{sub}\n#{opts(entry)}", "Opts.a(opts, options, Sub.new)"))).to eq([])
    end

    it "floors a def whose class has a namespaced subclass" do
      sub = "module Ns\n  class Sub < ::Helper\n    def really(parser, options) = #{writer}\n  end\nend"
      expect(rules(program("#{base}\n#{sub}\n#{opts(entry)}", "Opts.a(opts, options, Ns::Sub.new)"))).to eq([])
    end

    it "floors a def whose class has a subclass written with a relative name" do
      defs = "module Ns\n  #{base.gsub("\n", "\n  ")}\n  class Sub < Helper\n    " \
             "def really(parser, options) = #{writer}\n  end\nend"
      expect(rules(program("#{defs}\n#{opts(entry)}", "Opts.a(opts, options, Ns::Sub.new)"))).to eq([])
    end

    it "floors a def in a module whose includer defines the hand-off target" do
      defs = "module Hm\n  def c(parser, options) = really(parser, options)\nend\n" \
             "class Inc\n  include Hm\n  def really(parser, options) = #{writer}\nend"
      expect(rules(program("#{defs}\n#{opts(entry)}", "Opts.a(opts, options, Inc.new)"))).to eq([])
    end
  end

  # `Class.new(Parent)`, a superclass reached through a constant alias, and an unreadable superclass expression are
  # subclass relations the superclass table does not spell, so every named owner is floor-all while one exists.
  describe "a subclass relation the superclass table does not spell" do
    let(:entry) { "def self.a(parser, options, h) = h.c(parser, options)" }
    let(:base) do
      "class Helper\n  def c(parser, options) = really(parser, options)\n  " \
        "def really(parser, options) = #{reader}\nend"
    end

    def check(extra)
      rules(program("#{base}\n#{extra}\n#{opts(entry)}", "Opts.a(opts, options, Helper.new)"))
    end

    it "floors when a Class.new(Helper) block overrides the hand-off target" do
      expect(check("Sub = Class.new(Helper) { def really(parser, options) = #{writer} }")).to eq([])
    end

    it "floors when the subclass is reached through a constant alias" do
      extra = "H2 = Helper\nclass Sub < H2\n  def really(parser, options) = #{writer}\nend"
      expect(check(extra)).to eq([])
    end

    it "floors when a superclass expression cannot be read" do
      extra = "class Sub < (rand < 0.5 ? Helper : Object)\n  def really(parser, options) = #{writer}\nend"
      expect(check(extra)).to eq([])
    end

    it "keeps the literal beside a class with a core superclass (control)" do
      expect(check("class Failure < StandardError\nend")).to eq(always)
    end
  end

  describe "a block receiver without a name" do
    let(:other) { helper(writer) }

    it "resolves `it` by name" do
      entry = "def self.a(parser, options, list) = list.each { it.c(parser, options) }"
      expect(rules(program("#{other}\n#{opts(entry)}", "Opts.a(opts, options, [Helper.new])"))).to eq([])
    end

    it "resolves `_1` by name" do
      entry = "def self.a(parser, options, list) = list.each { _1.c(parser, options) }"
      expect(rules(program("#{other}\n#{opts(entry)}", "Opts.a(opts, options, [Helper.new])"))).to eq([])
    end
  end

  describe "the cap on same-named defs" do
    let(:entry) { "def self.a(parser, options, h) = h.c(parser, options)" }

    def readers(count) = (1..count).map { |i| "class Reader#{i}\n  def c(parser, options) = #{reader}\nend" }.join("\n")

    it "walks eight read-only defs and keeps the literal" do
      defs = "#{readers(8)}\n#{opts(entry)}"
      expect(rules(program(defs, "Opts.a(opts, options, Reader1.new)"))).to eq(always)
    end

    it "floors the handed parameter outright above eight" do
      defs = "#{readers(9)}\n#{opts(entry)}"
      expect(rules(program(defs, "Opts.a(opts, options, Reader1.new)"))).to eq([])
    end
  end
end
