# frozen_string_literal: true

# Issue #3006 — a receiverless or `self.` `send` / `public_send` / `__send__` written in a class body, whose method
# name is computed and which passes at least one further argument, may be an `include`, `prepend` or `extend` the
# mixin walks cannot record. The class's instance side (and, for a name that may be `extend`, its singleton side)
# then holds a module no name spells, so `call.undefined-method` must not fire there. A name that is a local of the
# call's scope bound only to literals that name no mixin (`m = :attr_reader`), or an interpolation with a literal part
# no mixin name contains, is not a mixin, and a `send` with no further argument cannot be one: those keep reporting.
# `sig/` declares every class, empty, so the rule runs. Every row's Ruby behaviour was witnessed on Ruby 4.0.5: each
# quiet call returns its module's value, and each reported call raises `NoMethodError`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a class body's computed-name `send` read as a mixin (#3006)" do
  let(:mods) { "module M1\n  def m1 = 1\nend\nmodule MA\n  def ma = 3\nend\n" }

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

  def check(body, sig: "class H\nend\n")
    undefined_messages({ "a.rb" => "#{mods}class H\n#{body}end\n" }, sig)
  end

  around do |example|
    Dir.mktmpdir("rigor-computed-send-mixin-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not fire after `meth = :include; send(meth, M1)`" do
    expect(check("  meth = :include\n  send(meth, M1)\n  def t = self.m1\n")).to be_empty
  end

  it "does not fire after `name = \"include\"; send(name.to_sym, M1)`" do
    expect(check("  name = \"include\"\n  send(name.to_sym, M1)\n  def t = self.m1\n")).to be_empty
  end

  it "does not fire after `__send__(meth, MA)` beside a recorded `include M1 if true`" do
    expect(check("  include M1 if true\n  meth = :include\n  __send__(meth, MA)\n  def t = self.ma\n")).to be_empty
  end

  it "does not fire after a `send` whose name is a block parameter" do
    expect(check("  [:include].each { |k| public_send(k, M1) }\n  def t = self.m1\n")).to be_empty
  end

  it "does not fire after a `send` in a `def self.` whose name is its parameter" do
    expect(check("  def self.setup(k) = send(k, M1)\n  setup(:include)\n  def t = self.m1\n")).to be_empty
  end

  it "does not fire when a block parameter shadows a local bound to `:attr_reader`" do
    # The block's `m` is not the body's, so the name is unknown.
    expect(check("  m = :attr_reader\n  [:include].each { |m| send(m, M1) }\n  def t = self.m1\n")).to be_empty
  end

  it "does not fire after a computed `send` in a block on a constant receiver" do
    expect(check("  KINDS = [:include]\n  KINDS.each { |m| send(m, M1) }\n  def t = self.m1\n")).to be_empty
  end

  it "does not fire on a subclass in another file after a computed `send` in a block on a constant receiver" do
    files = { "a.rb" => "#{mods}class H\n  KINDS = [:include]\n  KINDS.each { |m| send(m, M1) }\nend\n",
              "b.rb" => "class Sub < H\n  def u = self.m1\nend\n" }
    expect(undefined_messages(files, "class H\nend\nclass Sub < H\nend\n")).to be_empty
  end

  def check_includer(con_body, includer_body)
    source = "#{mods}module Con\n#{con_body}end\nclass P\n  include Con\n#{includer_body}end\n"
    undefined_messages({ "a.rb" => source }, "class P\nend\nmodule Con\nend\n")
  end

  # Guard: a concern's `included do` block already opens its includer without this reading, so the row passes with or
  # without the class-body block reach; it pins that the computed `send` there keeps the includer open.
  it "does not fire on a class including a concern whose `included do` block runs a computed `send`" do
    con = "  extend ActiveSupport::Concern\n  included do\n    k = :include\n    send(k, M1)\n  end\n"
    expect(check_includer(con, "  def t = self.m1\n")).to be_empty
  end

  it "does not fire on a class including a module whose hook sends a computed name to its parameter" do
    hook = "  def self.included(base)\n    meth = :include\n    base.send(meth, M1)\n  end\n"
    expect(check_includer(hook, "  def t = self.m1\n")).to be_empty
  end

  it "still fires on a class including a module whose hook sends a non-mixin computed name to its parameter" do
    hook = "  def self.included(base)\n    meth = :attr_reader\n    base.send(meth, :x)\n  end\n"
    expect(check_includer(hook, "  def t = self.nope\n")).to eq(["undefined method `nope' for P"])
  end

  it "does not fire on a subclass declared in another file" do
    files = { "a.rb" => "#{mods}class H\n  meth = :prepend\n  send(meth, M1)\nend\n",
              "b.rb" => "class Sub < H\n  def u = self.m1\nend\n" }
    expect(undefined_messages(files, "class H\nend\nclass Sub < H\nend\n")).to be_empty
  end

  it "does not fire on the singleton side after a computed name that may be `extend`" do
    expect(check("  k = \"extend\".to_sym\n  send(k, M1)\n  def self.s = self.m1\n")).to be_empty
  end

  it "does not fire on the singleton side after a local bound only to `:extend`" do
    expect(check("  k = :extend\n  send(k, M1)\n  def self.s = self.m1\n")).to be_empty
  end

  it "does not fire on the singleton side after a computed `include` in `class << self`" do
    expect(check("  class << self\n    k = :include\n    send(k, M1)\n  end\n  def self.s = self.m1\n")).to be_empty
  end

  describe "a name that is not a mixin's" do
    it "still fires after `m = :attr_reader; send(m, :x)`" do
      expect(check("  m = :attr_reader\n  send(m, :x)\n  def t = self.nope\n"))
        .to eq(["undefined method `nope' for H"])
    end

    it "still fires after an interpolated name with a literal part no mixin name contains" do
      expect(check("  kind = \"reader\"\n  send(\"attr_\#{kind}\", :x)\n  def t = self.nope\n"))
        .to eq(["undefined method `nope' for H"])
    end

    it "still fires on the instance side after a local bound only to `:extend`" do
      expect(check("  k = :extend\n  send(k, M1)\n  def t = self.m1\n")).to eq(["undefined method `m1' for H"])
    end

    it "still fires after a `send` with no further argument" do
      expect(check("  m = \"name\".to_sym\n  send(m)\n  def t = self.nope\n")).to eq(["undefined method `nope' for H"])
    end

    it "still fires after a computed `send` in an instance method" do
      expect(check("  def go(k) = send(k, M1)\n  def t = self.nope\n")).to eq(["undefined method `nope' for H"])
    end

    it "still fires after a computed `send` on another receiver" do
      expect(check("  k = \"extend\".to_sym\n  Object.new.send(k, M1)\n  def t = self.nope\n"))
        .to eq(["undefined method `nope' for H"])
    end
  end

  # Issue #3024 — the first block parameter of `each` / `each_with_index` / `map` over a literal array (or a
  # constant the class body assigns a literal array) holds each element in turn, so the elements are the
  # candidate names: `[:before_save].each` names no mixin and stays closed, `[:include].each` still marks.
  describe "a block parameter fed by a literal array (#3024)" do
    it "still fires after `[:before_save, :after_save].each` — every element names no mixin" do
      expect(check("  [:before_save, :after_save].each { |cb| send(cb, :x) }\n  def t = self.nope\n"))
        .to eq(["undefined method `nope' for H"])
    end

    it "does not fire after `[:include].each`" do
      expect(check("  [:include].each { |k| send(k, M1) }\n  def t = self.m1\n")).to be_empty
    end

    it "does not fire after `[:include].map`" do
      expect(check("  [:include].map { |k| send(k, M1) }\n  def t = self.m1\n")).to be_empty
    end

    it "does not fire after `each_with_index` over `[:include]`" do
      expect(check("  [:include].each_with_index { |k, i| send(k, M1) }\n  def t = self.m1\n")).to be_empty
    end

    it "still fires after `KINDS = [:before_save]`" do
      expect(check("  KINDS = [:before_save]\n  KINDS.each { |k| send(k, M1) }\n  def t = self.m1\n"))
        .to eq(["undefined method `m1' for H"])
    end

    it "does not fire after `KINDS = [:include]`" do
      expect(check("  KINDS = [:include]\n  KINDS.each { |k| send(k, M1) }\n  def t = self.m1\n"))
        .to be_empty
    end

    it "does not fire when an element is not a name literal" do
      expect(check("  [:include, name].each { |k| send(k, M1) }\n  def t = self.m1\n")).to be_empty
    end

    it "does not fire when the iterated receiver is not a literal array or a same-scope constant" do
      expect(check("  registry.each { |k| send(k, M1) }\n  def t = self.m1\n")).to be_empty
    end

    it "does not fire when the constant is written twice" do
      expect(check("  KINDS = [:before_save]\n  KINDS = [:include]\n  KINDS.each { |k| send(k, M1) }\n  " \
                   "def t = self.m1\n")).to be_empty
    end

    it "does not fire when the constant's value is not an array literal" do
      expect(check("  KINDS = build_kinds\n  KINDS.each { |k| send(k, M1) }\n  def t = self.m1\n"))
        .to be_empty
    end

    it "does not fire when a nested declaration writes the same constant name" do
      # `Inner::KINDS` is not `H::KINDS`: the class body's `KINDS` is unwritten here, so the parameter may
      # hold anything.
      body = "  class Inner\n    KINDS = [:before_save]\n  end\n  " \
             "KINDS.each { |k| send(k, M1) }\n  def t = self.m1\n"
      expect(check(body)).to be_empty
    end
  end
end
