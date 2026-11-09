# frozen_string_literal: true

# Issue #2997 — two more ways a module a class includes extends the class object, which #2996 and #2989 did not read:
# a `class_methods do … end` block in a reopening of a concern that does not repeat `extend ActiveSupport::Concern`,
# and an `included` / `prepended` hook defined as `class << self; def included(base)` or
# `define_singleton_method(:included) { |base| … }`. The includer's singleton resolution chain answered the
# superclass, or reported the method undefined.
#
# Every row's Ruby behaviour was witnessed on Ruby 4.0.5 with activesupport 8.1.4 loaded (`require
# "active_support/concern"`, left out here since the walk reads syntax only), each `lib/` file loaded in name order.
# The concern sits in its own file, the includer in another and the calls in a third; `sig/` declares every class and
# module, empty, so RBS answers no call. A call `.zork` on a result reports the type the read gave it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "reopened concern class_methods and hook spellings (#2997)" do
  around do |example|
    Dir.mktmpdir("rigor-concern-reopen-hook-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # `files` maps `lib/` file names to their source; `calls` go in `lib/use.rb`; `members` maps a declared name to the
  # members its declaration lists.
  def write_project(files, calls, members: {})
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    declared = files.values.flat_map { |body| body.scan(/^\s*(class|module) ([\w:]+)( < \w+)?/) }.uniq
    sig = declared.map { |kind, name, superclass| "#{kind} #{name}#{superclass}\n#{members[name]}end\n" }.join
    File.write(File.join("sig", "types.rbs"), sig)
    files.each { |name, body| File.write(File.join("lib", name), body) }
    File.write(File.join("lib", "use.rb"), "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  def base_class = "class Base\n  def self.bar = 1\n  def self.baz = 2\nend\n"

  describe "a class_methods block in a reopening without the extend" do
    let(:declares) { "module Cr\n  extend ActiveSupport::Concern\n  def own = 1\nend\n" }

    def reopening(body) = "module Cr\n  class_methods do\n#{body}  end\nend\n"

    def includer = "#{base_class}class Kr < Base\n  include Cr\nend\n"

    # Ruby answers "S": `Cr` is a concern when `b_reopen.rb` runs. Loaded first, the reopening raises NoMethodError
    # (`class_methods` is undefined on a plain module), so no running program has `Kr` without the method.
    it "answers the reopening's def ahead of the superclass's" do
      write_project({ "a_cr.rb" => declares, "b_reopen.rb" => reopening("    def bar = \"s\"\n"),
                      "k.rb" => includer }, ["Kr.bar.upcase", "Kr.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"s\""])
    end

    it "still reports a class-side name no module or class provides" do
      write_project({ "a_cr.rb" => declares, "b_reopen.rb" => reopening("    def bar = \"s\"\n"),
                      "k.rb" => includer }, ["Kr.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for singleton(Kr)"])
    end

    # Ruby raises NoMethodError: `private` in the block makes `priv` a private method of the class object. The read
    # withholds, so the result is `Dynamic`.
    it "does not answer a private def of the reopening's block" do
      write_project({ "a_cr.rb" => declares, "b_reopen.rb" => reopening("    private\n    def priv = 2\n"),
                      "k.rb" => includer }, ["Kr.priv.zork"])
      expect(undefined_messages).to be_empty
    end

    # No file extends `Cn` with Concern: its own `class_methods` takes the block and defines nothing, and Ruby
    # answers `bar` from `Base`.
    it "does not read the block of a module no file declares a concern" do
      declares = "module Cn\n  def self.class_methods(&) = nil\n  def own = 1\nend\n"
      write_project({ "a_cn.rb" => declares, "b_reopen.rb" => "module Cn\n  class_methods do\n    " \
                                                              "def bar = \"s\"\n  end\nend\n",
                      "k.rb" => "#{base_class}class Kn < Base\n  include Cn\nend\n" }, ["Kn.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end
  end

  # Issue #2997 — `Nm2`'s own `class_methods` (from `Dsl`) takes the block and defines nothing: `Nm2` is no concern,
  # so Ruby has no `Nm2::ClassMethods` and `Cx.const_get(:ClassMethods)` does not find one through `Nm2`. Ruby
  # answers 1 for both includers.
  describe "a class_methods block of a module no file declares a concern, behind a concern" do
    let(:files) do
      { "a_dsl.rb" => "module Dsl\n  def class_methods(&b) = nil\nend\n",
        "b_nm.rb" => "module Nm2\n  extend Dsl\n  class_methods do\n    def bar = \"phantom\"\n  end\nend\n",
        "c_cx.rb" => "module Cx\n  extend ActiveSupport::Concern\n  include Nm2\n  def own = 1\nend\n" }
    end

    it "does not answer it through the concern's const_get" do
      write_project(files.merge("k.rb" => "#{base_class}class Kx < Base\n  include Cx\nend\n"), ["Kx.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end

    it "does not answer it for a direct includer" do
      write_project(files.merge("k.rb" => "#{base_class}class Kn < Base\n  include Nm2\nend\n"), ["Kn.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end
  end

  # Issue #2997 — an interpolated name whose literal start no hook name has defines no hook, so the includer's class
  # side stays as it was: Ruby answers 1 and raises on `nope`.
  {
    "a class << self define_method" =>
      "module M8\n  class << self\n    %w[a b].each { |n| define_method(\"is_#{'#{n}'}\") { true } }\n  end\nend\n",
    "a define_singleton_method" =>
      "module M8\n  %w[a b].each { |n| define_singleton_method(\"is_#{'#{n}'}\") { true } }\nend\n"
  }.each do |label, source|
    it "reads no hook from #{label} with an is_ prefix" do
      write_project({ "m8.rb" => source, "k.rb" => "#{base_class}class K8 < Base\n  include M8\n  def own = 1\nend\n" },
                    ["K8.bar.zork", "K8.nope"], members: { "K8" => "  def own: () -> Integer\n" })
      expect(undefined_messages).to eq(["undefined method `nope' for singleton(K8)", "undefined method `zork' for 1"])
    end
  end

  describe "a hook defined without def self." do
    def x_module = "module X\n  def bar = \"X\"\nend\n"

    def project(hook, calls)
      write_project({ "a_x.rb" => x_module, "hook.rb" => hook,
                      "k.rb" => "#{base_class}class Ku < Base\n  include Hu\nend\n" }, calls)
    end

    # The `class << self` rows are guards: a `def` in that body already reached #2996's hook read as a singleton
    # `def`, and the issue's report of it did not reproduce on this branch's base. So is the declining row for
    # `def self.included and then class << self; def included`.
    {
      "define_singleton_method(:included) with a block" =>
        "module Hu\n  define_singleton_method(:included) { |base| base.extend(X) }\nend\n",
      "self.define_singleton_method(:included) with a do block" =>
        "module Hu\n  self.define_singleton_method(:included) do |base|\n    base.extend(X)\n  end\nend\n",
      "class << self; def included" =>
        "module Hu\n  class << self\n    def included(base) = base.extend(X)\n  end\nend\n",
      "a private class << self; def included" =>
        "module Hu\n  class << self\n    private\n\n    def included(base)\n      base.extend(X)\n    end\n  " \
        "end\nend\n"
    }.each do |label, hook|
      it "answers the module a #{label} hook extends" do
        project(hook, ["Ku.bar.upcase", "Ku.bar.zork"])
        expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
      end
    end

    # `Ku`'s declaration lists a member: a member-less one whose singleton side a module extends may hold methods
    # the source does not show (#2438), for a `def self.included` hook as for these.
    it "still reports a class-side name no module or class provides" do
      write_project({ "a_x.rb" => x_module,
                      "hook.rb" => "module Hu\n  define_singleton_method(:included) { |base| base.extend(X) }\nend\n",
                      "k.rb" => "#{base_class}class Ku < Base\n  include Hu\n  def own = 1\nend\n" },
                    ["Ku.zork"], members: { "Ku" => "  def own: () -> Integer\n" })
      expect(undefined_messages).to eq(["undefined method `zork' for singleton(Ku)"])
    end

    # Ruby raises NoMethodError: X is on the class object's ancestry, not its instances'.
    it "still reports an instance-side call to the extended module's method" do
      project("module Hu\n  define_singleton_method(:included) { |base| base.extend(X) }\n  def own = 1\nend\n",
              ["Ku.new.bar"])
      expect(undefined_messages).to eq(["undefined method `bar' for Ku"])
    end

    # Ruby answers 1 for each: none of these defines `Hu.included` or `Hu.prepended`.
    {
      "a define_singleton_method of another name" =>
        "module Hu\n  define_singleton_method(:setup) { |base| base.extend(X) }\nend\n",
      "a define_singleton_method in a class << self body" =>
        "module Hu\n  class << self\n    define_singleton_method(:included) { |base| base.extend(X) }\n  end\nend\n",
      "a define_singleton_method in an instance method" =>
        "module Hu\n  def setup = define_singleton_method(:included) { |base| base.extend(X) }\nend\n",
      "a prepended hook, for an including class" =>
        "module Hu\n  define_singleton_method(:prepended) { |base| base.extend(X) }\nend\n"
    }.each do |label, hook|
      it "does not read #{label}" do
        project(hook, ["Ku.bar.zork"])
        expect(undefined_messages).to eq(["undefined method `zork' for 1"])
      end
    end

    # Ruby answers "X" for each but the last three, which answer 1: the hook defined last does not extend. The read
    # cannot place the extend, so it declines rather than answering either Base's 1 or X's "X". `baz`, which only Base
    # defines, declines too: the hook may extend with a module that defines it.
    {
      "a computed hook name" =>
        "module Hu\n  name = :included\n  define_singleton_method(name) { |base| base.extend(X) }\nend\n",
      "an interpolated name that may still spell included" =>
        "module Hu\n  x = \"luded\"\n  define_singleton_method(\"inc#{'#{x}'}\") { |base| base.extend(X) }\nend\n",
      "a define_singleton_method nested in a block" =>
        "module Hu\n  [1].each { define_singleton_method(:included) { |base| base.extend(X) } }\nend\n",
      "a define_singleton_method in a singleton method" =>
        "module Hu\n  def self.setup = define_singleton_method(:included) { |base| base.extend(X) }\n  setup\nend\n",
      "a hook block's extend after an early next" =>
        "module Hu\n  define_singleton_method(:included) do |base|\n    next if base.nil?\n    base.extend(X)\n  " \
        "end\nend\n",
      "a hook block's conditional extend" =>
        "module Hu\n  define_singleton_method(:included) { |base| base.extend(X) if base.name }\nend\n",
      "a hook block with a numbered parameter" =>
        "module Hu\n  define_singleton_method(:included) { _1.extend(X) }\nend\n",
      "a hook given as a block argument" =>
        "module Hu\n  HOOK = proc { |base| base.extend(X) }\n  define_singleton_method(:included, &HOOK)\nend\n",
      "a send(:define_singleton_method)" =>
        "module Hu\n  send(:define_singleton_method, :included) { |base| base.extend(X) }\nend\n",
      "a singleton_class.define_method" =>
        "module Hu\n  singleton_class.define_method(:included) { |base| base.extend(X) }\nend\n",
      "a define_method in a class << self body" =>
        "module Hu\n  class << self\n    define_method(:included) { |base| base.extend(X) }\n  end\nend\n",
      "def self.included and then class << self; def included" =>
        "module Hu\n  def self.included(base) = base.extend(X)\n  class << self\n    def included(base) = nil\n  " \
        "end\nend\n",
      "define_singleton_method(:included) and then def self.included" =>
        "module Hu\n  define_singleton_method(:included) { |base| base.extend(X) }\n  " \
        "def self.included(base) = nil\nend\n",
      "class << self; def included and then define_singleton_method(:included)" =>
        "module Hu\n  class << self\n    def included(base) = base.extend(X)\n  end\n  " \
        "define_singleton_method(:included) { |base| nil }\nend\n"
    }.each do |label, hook|
      it "declines for #{label}" do
        project(hook, ["Ku.bar.upcase", "Ku.bar.even?", "Ku.baz.zork"])
        expect(undefined_messages).to be_empty
      end
    end

    # Ruby raises NoMethodError: `Hu.setup` never runs, so `Ku` has no `my_attr` and the guarded call defines nothing.
    # A hook-named entry for `setup` would let the class-body macro reader find `X#my_attr` and open `Ku`.
    it "does not read a define_singleton_method of another name as a macro's source" do
      write_project({ "a_x.rb" => "module X\n  def my_attr(n) = define_method(n) { 1 }\nend\n",
                      "hook.rb" => "module Hu\n  define_singleton_method(:setup) { |base| base.extend(X) }\n  " \
                                   "def own = 1\nend\n",
                      "k.rb" => "class Ku\n  include Hu\n  my_attr :foo if name.nil?\nend\n" }, ["Ku.new.foo"])
      expect(undefined_messages).to eq(["undefined method `foo' for Ku"])
    end

    it "reads a define_singleton_method(:prepended) hook for a prepending class" do
      write_project({ "a_x.rb" => x_module,
                      "hook.rb" => "module Hu\n  define_singleton_method(:prepended) { |base| base.extend(X) }\nend\n",
                      "k.rb" => "#{base_class}class Kp < Base\n  prepend Hu\nend\n" }, ["Kp.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end
  end
end
