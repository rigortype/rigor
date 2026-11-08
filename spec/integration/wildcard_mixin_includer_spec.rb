# frozen_string_literal: true

# Issue #2991 — a splatted `include(*MODS)` / `prepend(*MODS)` mixes in modules the tables cannot name, so every
# name on the class's instance side may come from one of them: `call.undefined-method` must not fire on the class,
# nor on a subclass at any depth. `Scope::ResolutionChain` marks such a chain (`wildcard_mixin?`), and the rule
# reads that mark. `sig/` declares every class so the rule runs. `Sup` defines a method of its own, so it is a project
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
end
