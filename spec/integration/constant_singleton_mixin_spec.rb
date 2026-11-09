# frozen_string_literal: true

# Issue #3010 — `class << Const; prepend Y; end` (or `include Y`) puts `Y` on `Const`'s singleton class, as `class <<
# self; prepend Y; end` in `Const`'s own body does: a prepend ahead of the class object's own `def self.` methods, an
# include behind them. A class-side call answers with `Y`'s method where the edge's position is a fact (a direct
# statement of the file that declares the class) and declines where it is not.
#
# Every row's Ruby behaviour was witnessed on Ruby 4.0.5, the two-file rows in both load orders. The modules sit in one
# file, the class in another and the calls in a third; `sig/` declares every class and module, empty, so RBS answers no
# call. A call `.zork` on a result reports the type the read gave it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a class << Const singleton mixin (#3010)" do
  around do |example|
    Dir.mktmpdir("rigor-constant-singleton-mixin-") { |dir| Dir.chdir(dir) { example.run } }
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
    "module Y\n  def foo = :y\nend\nmodule Z\n  def foo = :z\nend\n" \
      "class Base\n  def self.foo = 0\n  def self.bar = 2\nend\n"
  end

  def zork(type) = "undefined method `zork' for #{type}"

  # The issue's witness: `Ku.singleton_class.ancestors` starts `[Y, #<Class:Ku>, #<Class:Base>]`.
  it "answers the prepended module on the class and on a subclass" do
    write_project("class Ku < Base\n  def self.foo = 1\nend\nclass << Ku\n  prepend Y\nend\nclass Sn < Ku\nend\n",
                  ["Ku.foo.zork", "Sn.foo.zork"])
    expect(undefined_messages).to eq([zork(":y")] * 2)
  end

  # `include` sits behind the class object's own def and ahead of the superclass's.
  it "answers an included module behind the class's own def" do
    write_project("class Ki < Base\nend\nclass << Ki\n  include Y\nend\n" \
                  "class Kj < Base\n  def self.foo = 1\nend\nclass << Kj\n  include Y\nend\n",
                  ["Ki.foo.zork", "Kj.foo.zork"])
    expect(undefined_messages).to eq([zork(1), zork(":y")])
  end

  # A `def` in the body is the class object's own, and the prepend sits ahead of it whichever is written first.
  it "puts the prepend ahead of a def in the same body, in either order" do
    write_project("class Kd < Base\nend\nclass << Kd\n  prepend Y\n  def foo = 1\nend\n" \
                  "class Ke < Base\nend\nclass << Ke\n  def foo = 1\n  prepend Y\nend\n" \
                  "class Kf < Base\nend\nclass << Kf\n  def foo = 1\nend\n",
                  ["Kd.foo.zork", "Ke.foo.zork", "Kf.foo.zork"])
    expect(undefined_messages).to eq([zork(1), zork(":y"), zork(":y")])
  end

  # Ruby inserts a later prepend ahead of an earlier one.
  it "answers the later of two prepends" do
    write_project("class K2 < Base\nend\nclass << K2\n  prepend Y\n  prepend Z\nend\n", ["K2.foo.zork"])
    expect(undefined_messages).to eq([zork(":z")])
  end

  # Ruby raises NoMethodError on `Kr.foo.even?`, and `Kr.bar` passes `Y`, which defines no `bar`, to `Base.bar`.
  it "reports past the prepended module, on its result and on a name it does not define" do
    write_project("class Kr < Base\n  def self.foo = 1\nend\nclass << Kr\n  prepend Y\nend\n",
                  ["Kr.foo.even?", "Kr.bar.zork"])
    expect(undefined_messages).to eq(["undefined method `even?' for :y", zork(2)])
  end

  # Ruby answers :y; the reopening may load before or after another prepend, so the position is not a fact.
  it "declines a prepend another file writes" do
    write_project("class Kt < Base\n  def self.foo = 1\nend\n", ["Kt.foo.zork"],
                  extra: { "shovel.rb" => "class << Kt\n  prepend Y\nend\n" })
    expect(undefined_messages).to be_empty
  end

  # Ruby answers :y when the condition holds or the method runs, and 1 otherwise.
  {
    "a conditional" => "class << Kc\n  prepend Y if $c\nend\n",
    "a method body" => "def setup\n  class << Kc\n    prepend Y\n  end\nend\n"
  }.each do |label, source|
    it "declines a prepend in #{label}" do
      write_project("class Kc < Base\n  def self.foo = 1\nend\n#{source}", ["Kc.foo.zork"])
      expect(undefined_messages).to be_empty
    end
  end

  describe "a nested constant" do
    let(:classes) do
      "class User < Base\n  def self.foo = 1\nend\nclass Plain < Base\nend\n" \
        "module Admin\n  class User < Base\n    def self.foo = 2\n  end\n  class Plain < Base\n  end\nend\n"
    end

    # Inside `module Admin`, `User` names `Admin::User` once that class exists, which the walk cannot tell from
    # another file: Ruby answers 1, :y, 0 and :y. Each candidate declines rather than answer its own def, or a module
    # the prepend may not have put on it.
    it "declines on every class the constant may name" do
      write_project(classes, ["User.foo.zork", "Admin::User.foo.zork", "Plain.foo.zork", "Admin::Plain.foo.zork"],
                    extra: { "admin.rb" => "module Admin\n  class << User\n    prepend Y\n  end\n  " \
                                           "class << Plain\n    prepend Y\n  end\nend\n" })
      expect(undefined_messages).to be_empty
    end

    # Ruby resolves `User` when the `class <<` runs, before the file declares `Admin::User`: Ruby answers :y and 2.
    it "declines on both classes when the nested class is declared after the class <<" do
      write_project("class User < Base\n  def self.foo = 1\nend\n" \
                    "module Admin\n  class << User\n    prepend Y\n  end\n  " \
                    "class User < Base\n    def self.foo = 2\n  end\nend\n",
                    ["User.foo.zork", "Admin::User.foo.zork"])
      expect(undefined_messages).to be_empty
    end

    # Another file declares `Admin::User` first, and this one reopens it after the `class <<`: Ruby answers 1 and :y.
    it "declines when another file declares the nested class and this one reopens it later" do
      write_project(classes, ["User.foo.zork", "Admin::User.foo.zork"],
                    extra: { "admin.rb" => "module Admin\n  class << User\n    prepend Y\n  end\n  " \
                                           "class User < Base\n  end\nend\n" })
      expect(undefined_messages).to be_empty
    end

    # The file declares `Admin::User` before the `class <<`, so the constant names it: Ruby answers 1 and :y.
    it "answers the prepend on the nested class its own file declares" do
      write_project("class User < Base\n  def self.foo = 1\nend\n" \
                    "module Admin\n  class User < Base\n    def self.foo = 2\n  end\n  " \
                    "class << User\n    prepend Y\n  end\nend\n",
                    ["User.foo.zork", "Admin::User.foo.zork"])
      expect(undefined_messages).to eq([zork(1), zork(":y")])
    end
  end
end
