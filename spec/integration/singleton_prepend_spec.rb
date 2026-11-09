# frozen_string_literal: true

# Issue #2998 — a prepend to a class object's own singleton class (`class << self; prepend Y; end`,
# `singleton_class.prepend Y`, `singleton_class.send(:prepend, Y)`) puts `Y` ahead of the class object's own
# `def self.` methods, as an instance-side `prepend` puts a module ahead of the class, while an `extend` sits behind
# them. A class-side call answers with `Y`'s method, on the class and on its subclasses.
#
# Every row's Ruby behaviour was witnessed on Ruby 4.0.5, the concern rows with activesupport 8.1.4 loaded (`require
# "active_support/concern"`, left out here since the walk reads syntax only), and the two-file rows in both load
# orders. The modules sit in one file, the class in another and the calls in a third; `sig/` declares every class and
# module, empty, so RBS answers no call. A call `.zork` on a result reports the type the read gave it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a singleton-side prepend of the class's own (#2998)" do
  around do |example|
    Dir.mktmpdir("rigor-singleton-prepend-") { |dir| Dir.chdir(dir) { example.run } }
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

  def concern(name, body) = "module #{name}\n  extend ActiveSupport::Concern\n#{body}end\n"

  def modules
    "module Y\n  def foo = :y\nend\nmodule Z\n  def foo = :z\nend\n" \
      "class Base\n  def self.foo = 0\n  def self.bar = 2\nend\n" \
      "#{concern('Cpe', "  class_methods do\n    def foo = \"s\"\n  end\n")}"
  end

  def zork(type) = "undefined method `zork' for #{type}"

  # The issue's witness: `Kn.singleton_class.ancestors` starts `[Y, #<Class:Kn>, Z, #<Class:Base>]`.
  it "answers the prepended module on the class and on a subclass" do
    write_project("class Kn < Base\n  def self.foo = 1\n  class << self\n    prepend Y\n  end\n  extend Z\nend\n" \
                  "class Sn < Kn\nend\n", ["Kn.foo.zork", "Sn.foo.zork"])
    expect(undefined_messages).to eq([zork(":y")] * 2)
  end

  {
    "singleton_class.prepend" => "singleton_class.prepend Y",
    "self.singleton_class.prepend" => "self.singleton_class.prepend Y",
    "singleton_class.send(:prepend)" => "singleton_class.send(:prepend, Y)"
  }.each do |label, statement|
    it "answers the module #{label} puts ahead of the class's own def" do
      write_project("class Kd < Base\n  def self.foo = 1\n  #{statement}\nend\n", ["Kd.foo.zork"])
      expect(undefined_messages).to eq([zork(":y")])
    end
  end

  # Ruby raises NoMethodError on `Kr.foo.even?`: the prepended module answers a Symbol.
  it "reports a call the prepended module's result does not answer" do
    write_project("class Kr < Base\n  def self.foo = 1\n  class << self\n    prepend Y\n  end\nend\n",
                  ["Kr.foo.even?"])
    expect(undefined_messages).to eq(["undefined method `even?' for :y"])
  end

  # A constant receiver's prepend runs wherever the call runs, so its order is not a fact; Ruby answers :y here.
  {
    "Kx.singleton_class.prepend" => "Kx.singleton_class.prepend Y",
    "Kx.singleton_class.send(:prepend)" => "Kx.singleton_class.send(:prepend, Y)"
  }.each do |label, statement|
    it "declines rather than answer the class's own def past #{label}" do
      write_project("class Kx < Base\n  def self.foo = 1\nend\n#{statement}\n", ["Kx.foo.zork"])
      expect(undefined_messages).to be_empty
    end
  end

  # Ruby inserts a later prepend ahead of an earlier one.
  it "answers the later of two prepends in one file" do
    write_project("class K2 < Base\n  def self.foo = 1\n  class << self\n    prepend Y\n    prepend Z\n  end\nend\n",
                  ["K2.foo.zork"])
    expect(undefined_messages).to eq([zork(":z")])
  end

  # An instance-side `prepend Y` puts nothing on the singleton: `extend Y` keeps `Y` behind the class object's own def.
  it "keeps an extend behind the class object beside an instance-side prepend of the same module" do
    write_project("class Kq < Base\n  def self.foo = 1\n  extend Y\n  prepend Y\nend\n", ["Kq.foo.zork"])
    expect(undefined_messages).to eq([zork(1)])
  end

  describe "a class declared in two files" do
    it "answers a prepend the other file writes" do
      write_project("class Kt < Base\n  def self.foo = 1\nend\n", ["Kt.foo.zork"],
                    extra: { "reopen.rb" => "class Kt < Base\n  class << self\n    prepend Y\n  end\nend\n" })
      expect(undefined_messages).to eq([zork(":y")])
    end

    # A prepend sits ahead of the class object and an `extend` behind it in either load order.
    it "answers a prepend in one file beside an extend in the other" do
      write_project("class Kv < Base\n  def self.foo = 1\n  class << self\n    prepend Y\n  end\nend\n",
                    ["Kv.foo.zork"], extra: { "reopen.rb" => "class Kv < Base\n  extend Z\nend\n" })
      expect(undefined_messages).to eq([zork(":y")])
    end

    # Ruby answers :z when the reopening loads second and :y when it loads first.
    it "declines between prepends the two files write" do
      write_project("class Ku < Base\n  def self.foo = 1\n  class << self\n    prepend Y\n  end\nend\n" \
                    "class Kw < Base\n  class << self\n    prepend Y\n  end\nend\n",
                    ["Ku.foo.zork", "Kw.foo.zork"],
                    extra: { "reopen.rb" => "class Ku < Base\n  class << self\n    prepend Z\n  end\nend\n" \
                                            "class Kw < Base\n  class << self\n    prepend Z\n  end\nend\n" })
      expect(undefined_messages).to be_empty
    end
  end

  # Ruby answers :y when the condition holds and 1 when it does not.
  it "declines a prepend whose position is not a fact" do
    write_project("class Kc < Base\n  def self.foo = 1\n  class << self\n    prepend Y if $c\n  end\nend\n",
                  ["Kc.foo.zork"])
    expect(undefined_messages).to be_empty
  end

  # `Concern#prepend_features` prepends `Cpe::ClassMethods` when `prepend Cpe` runs: Ruby answers :y for Kh1 and "s"
  # for Kh2. `Base.bar` sits behind both, whatever their order.
  describe "beside a prepended concern" do
    let(:includer) do
      "class Kh1 < Base\n  prepend Cpe\n  class << self\n    prepend Y\n  end\nend\n" \
        "class Kh2 < Base\n  class << self\n    prepend Y\n  end\n  prepend Cpe\nend\n"
    end

    it "declines a name both prepends define, in either statement order" do
      write_project(includer, ["Kh1.foo.zork", "Kh2.foo.zork"])
      expect(undefined_messages).to be_empty
    end

    it "answers a name behind the class object" do
      write_project(includer, ["Kh1.bar.zork", "Kh2.bar.zork"])
      expect(undefined_messages).to eq([zork(2)] * 2)
    end
  end

  # Part 2 — an `extend` sits behind the class object and a prepended concern's `ClassMethods` ahead of it, so the
  # two statements' order does not matter: Ruby answers "s" for both.
  it "answers a prepended concern beside an extend in either statement order" do
    write_project("module Xpe\n  def foo = :x\nend\nclass Kpe1 < Base\n  extend Xpe\n  prepend Cpe\nend\n" \
                  "class Kpe2 < Base\n  prepend Cpe\n  extend Xpe\nend\n", ["Kpe1.foo.zork", "Kpe2.foo.zork"])
    expect(undefined_messages).to eq([zork('"s"')] * 2)
  end

  # Only `Hw::ClassMethods` defines `hh`; Ruby answers "h".
  it "answers an included concern's class method beside a prepended concern and an extend" do
    concerns = concern("Hw", "  class_methods do\n    def hh = \"h\"\n  end\n") +
               concern("Cw", "  class_methods do\n    def cw = 1\n  end\n")
    write_project("#{concerns}module Xw\n  def xw = 2\nend\nclass Kw\n  include Hw\n  prepend Cw\n  extend Xw\nend\n",
                  ["Kw.hh.zork"])
    expect(undefined_messages).to eq([zork('"h"')])
  end

  describe "the singleton chain" do
    def chain_names(source, name)
      root = Prism.parse(source).value
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
      Rigor::Scope::ResolutionChain.for(scope, name, :singleton, :methods).entries.map { |entry| entry.name || entry.raw }
    end

    it "puts each spelling's module ahead of the class object and an extend behind it" do
      ["class << self\n    prepend Y\n  end", "singleton_class.prepend Y",
       "singleton_class.send(:prepend, Y)"].each do |statement|
        source = "#{modules}class Kn < Base\n  #{statement}\n  extend Z\nend\nclass Sn < Kn\nend\n"
        expect(chain_names(source, "Sn")).to eq(%w[Sn Y Kn Z Base])
      end
    end

    it "keeps a class << self include behind the class object" do
      source = "#{modules}class Ki < Base\n  class << self\n    include Y\n  end\nend\n"
      expect(chain_names(source, "Ki")).to eq(%w[Ki Y Base])
    end
  end
end
