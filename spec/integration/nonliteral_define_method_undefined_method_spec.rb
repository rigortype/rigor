# frozen_string_literal: true

# Issue #2793 — a `define_method` whose name is not a literal (`%i[a b].each { |m| define_method(m) { } }`) defines
# methods no table can name, so `call.undefined-method` must read the class as open once a `sig/` declares it
# without them, as it reads a source `method_missing`. It opens only the class `self` is where the call runs: a
# `Class.new { }` / `Struct.new { }` body or another receiver's `instance_eval` is another class's, and a
# `class << self` body opens the singleton side alone. Each row's Ruby behaviour was witnessed on Ruby 4.0.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "A non-literal define_method and call.undefined-method (#2793)" do
  def write_project(source, calls, extra_files: {})
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    classes = source.scan(/^class (\w+)/).flatten.uniq
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
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-nonliteral-define-method-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "opens the instance side for a define_method in an each block, and not the class object" do
    write_project("class Dyn\n  %i[a b].each { |m| define_method(m) { m } }\nend\n", %w[Dyn.new.a Dyn.a])
    expect(undefined_messages).to eq(["undefined method `a' for singleton(Dyn)"])
  end

  it "opens the class for a define_method at the class body's top level and under a condition" do
    source = "class Top\n  m = :t\n  define_method(m) { 1 }\nend\n" \
             "class Cond\n  m = :c\n  define_method(m) { 1 } if rand > 0.5\nend\n"
    write_project(source, %w[Top.new.t Cond.new.c])
    expect(undefined_messages).to be_empty
  end

  it "opens a subclass through its project ancestor" do
    write_project("class Dyn\n  %i[a].each { |m| define_method(m) { m } }\nend\nclass Child < Dyn\nend\n",
                  %w[Child.new.zz])
    expect(undefined_messages).to be_empty
  end

  it "opens the class when another file reopens it with the define_method" do
    write_project("class Reopen\nend\n", %w[Reopen.new.r],
                  extra_files: { "reopen.rb" => "class Reopen\n  [:r].each { |m| define_method(m) { 1 } }\nend\n" })
    expect(undefined_messages).to be_empty
  end

  # Guard: the walk's placement (a meta-new body's own owner prefix) keeps the mark off the outer class, not a line
  # of this change; it fails if the mark is ever filed under the lexical class instead.
  it "does not open the enclosing class for a define_method in a Class.new or Struct.new body" do
    source = "class Outer\n  K = Class.new { [:k].each { |m| define_method(m) { 1 } } }\nend\n" \
             "class SOuter\n  S = Struct.new(:x) { [:s].each { |m| define_method(m) { 1 } } }\nend\n"
    write_project(source, %w[Outer.new.k SOuter.new.s])
    expect(undefined_messages).to eq(["undefined method `k' for Outer", "undefined method `s' for SOuter"])
  end

  it "opens the singleton side alone for a define_method in a class << self body" do
    write_project("class Sing\n  class << self\n    [:q].each { |m| define_method(m) { 1 } }\n  end\nend\n",
                  %w[Sing.q Sing.new.q])
    expect(undefined_messages).to eq(["undefined method `q' for Sing"])
  end

  it "opens instance_eval's receiver, which is the class itself only when the call has none" do
    source = "class Helper\nend\n" \
             "class IE\n  Helper.instance_eval { [:h].each { |m| define_method(m) { 1 } } }\nend\n" \
             "class IE2\n  instance_eval { [:j].each { |m| define_method(m) { 1 } } }\nend\n"
    write_project(source, %w[IE.new.h Helper.new.h IE2.new.j])
    expect(undefined_messages).to eq(["undefined method `h' for IE"])
  end

  it "opens the class for a define_method written with an explicit self receiver" do
    write_project("class SelfDm\n  [:sd].each { |m| self.define_method(m) { 1 } }\nend\n", %w[SelfDm.new.sd])
    expect(undefined_messages).to be_empty
  end

  it "does not open the class for a define_method on another receiver" do
    write_project("class Other\nend\nclass Host\n  m = :x\n  Other.define_method(m) { 1 }\nend\n", %w[Host.new.x])
    expect(undefined_messages).to eq(["undefined method `x' for Host"])
  end
end
