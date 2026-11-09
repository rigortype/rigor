# frozen_string_literal: true

# Issue #3020 — a prepend to a class object's own singleton class whose module no table names
# (`class << self; prepend(*MODS); end`, `singleton_class.prepend(*MODS)`) may put any method ahead of the class
# object's own `def self.` methods, so a class-side call that the class object or anything behind it answers is
# declined rather than answered with the own def. An unnamed `extend` or `class << self` `include` sits behind the
# class object, so its own def still answers, and a definer behind it (a superclass's `def self.`) is declined.
#
# Every row's Ruby behaviour was witnessed on Ruby 4.0.5. The modules sit in one file, the class in another and the
# calls in a third; `sig/` declares every class and module, empty, so RBS answers no call. A call `.zork` on a result
# reports the type the read gave it; an empty report is a declined read.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "an unnamed singleton-side mixin of the class's own (#3020)" do
  around do |example|
    Dir.mktmpdir("rigor-unnamed-singleton-prepend-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # `extra` maps more `lib/` file names to their source.
  def write_project(includer, calls, extra: {})
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    sources = [modules, includer, *extra.values]
    declared = sources.flat_map { |body| body.scan(/^\s*(class|module) ([\w:]+( < \w+)?)/) }.uniq
    File.write(File.join("sig", "types.rbs"), declared.map { |kind, name| "#{kind} #{name}\nend\n" }.join)
    File.write(File.join("lib", "modules.rb"), modules)
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

  def modules
    "module Ya\n  def foo = :a\n  def bar = :b\nend\nMODS = [Ya]\nclass Base\n  def self.bar = 0\nend\n"
  end

  def zork(type) = "undefined method `zork' for #{type}"

  # Ruby answers :a for each: `Ya` sits ahead of `#<Class:Kt>`. The `send` row is a guard: master declined that
  # spelling before #3020, on another route.
  {
    "class << self; prepend(*MODS)" => "class << self\n    prepend(*MODS)\n  end",
    "singleton_class.prepend(*MODS)" => "singleton_class.prepend(*MODS)",
    "singleton_class.send(:prepend, *MODS)" => "singleton_class.send(:prepend, *MODS)"
  }.each do |label, statement|
    it "declines rather than answer the class's own def past #{label}" do
      write_project("class Kt < Base\n  def self.foo = 1\n  #{statement}\nend\n", ["Kt.foo.zork"])
      expect(undefined_messages).to be_empty
    end
  end

  # Ruby answers :a: `class << Kt` after the class body opens the same singleton class (#3019).
  it "declines rather than answer the class's own def past class << Kt; prepend(*MODS)" do
    write_project("class Kt < Base\n  def self.foo = 1\nend\nclass << Kt\n  prepend(*MODS)\nend\n", ["Kt.foo.zork"])
    expect(undefined_messages).to be_empty
  end

  # Ruby answers :a for `Sub.foo` and :b for `Kt.bar`, past `Base.bar`; `Sub.baz` is Sub's own, ahead of Kt's level.
  it "declines on a subclass and past the superclass, and answers a subclass's own def" do
    write_project("class Kt < Base\n  def self.foo = 1\n  class << self\n    prepend(*MODS)\n  end\nend\n" \
                  "class Sub < Kt\n  def self.baz = 3\nend\n",
                  ["Sub.foo.zork", "Kt.bar.zork", "Sub.baz.zork"])
    expect(undefined_messages).to eq([zork(3)])
  end

  # Ruby answers :a: the literal prepend's module is named, so the #2998 read answers it.
  it "answers a literal prepend's module" do
    write_project("class Kl < Base\n  def self.foo = 1\n  class << self\n    prepend Ya\n  end\nend\n", ["Kl.foo.zork"])
    expect(undefined_messages).to eq([zork(":a")])
  end

  # Ruby answers 1 for both: an unnamed `extend` or `class << self` `include` sits behind the class object.
  it "answers the own def past an unnamed extend or class << self include" do
    write_project("class Ke < Base\n  def self.foo = 1\n  extend(*MODS)\nend\n" \
                  "class Ki < Base\n  def self.foo = 1\n  class << self\n    include(*MODS)\n  end\nend\n",
                  ["Ke.foo.zork", "Ki.foo.zork"])
    expect(undefined_messages).to eq([zork(1)] * 2)
  end

  # An unnamed `extend` sits behind the class object's own singleton and ahead of its superclass's, so a superclass
  # `def self.` is withheld. Ruby answers :b for each `bar`, 1 for `Ke.foo` and 3 for `Se.baz`.
  describe "past an unnamed extend" do
    let(:includer) do
      "class Ke < Base\n  def self.foo = 1\n  extend(*MODS)\nend\nclass Se < Ke\n  def self.baz = 3\nend\n"
    end

    it "declines a superclass's def on the class and on a subclass, and answers their own defs" do
      write_project(includer, ["Ke.bar.zork", "Se.bar.zork", "Ke.foo.zork", "Se.baz.zork"])
      expect(undefined_messages).to eq([zork(1), zork(3)])
    end

    it "declines a superclass's def when a reopening in another file writes the extend" do
      write_project("class Kr < Base\n  def self.foo = 1\nend\n", ["Kr.bar.zork", "Kr.foo.zork"],
                    extra: { "reopen.rb" => "class Kr < Base\n  extend(*MODS)\nend\n" })
      expect(undefined_messages).to eq([zork(1)])
    end

    # Ruby answers :b: a `class << self` `include` sits where an `extend` does.
    it "declines a superclass's def past a class << self include" do
      write_project("class Ki < Base\n  class << self\n    include(*MODS)\n  end\nend\n", ["Ki.bar.zork"])
      expect(undefined_messages).to be_empty
    end
  end
end
