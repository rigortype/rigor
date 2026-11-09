# frozen_string_literal: true

# Issue #3005 — three ways a concern reaches its includer that the concern reader missed: an `included` /
# `prepended` block in a reopening of a concern that does not repeat `extend ActiveSupport::Concern`, a `def self.x`
# in such a block (Ruby runs the block in the includer's class body, so it defines `x` on the includer's singleton
# class), and a module that writes `self.extend ActiveSupport::Concern` or `send(:extend, ActiveSupport::Concern)`.
#
# Every row's Ruby behaviour was witnessed on Ruby 4.0.5 with activesupport 8.1.4 loaded (`require
# "active_support/concern"`, left out here since the walk reads syntax only), each `lib/` file loaded in name order.
# Each concern sits in its own file, the includer in another and the calls in a third; `sig/` declares every class
# and module, empty, so RBS answers no call. A call `.zork` on a result reports the type the read gave it.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "concern reader gaps (#3005)" do
  around do |example|
    Dir.mktmpdir("rigor-concern-reader-gaps-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # `files` maps `lib/` file names to their source; `calls` go in `lib/use.rb`; `members` maps a declared name to the
  # members its declaration lists. An includer whose declaration lists none, and whose singleton chain holds a module,
  # is open on its class side (#2438), so a row that expects a report on it gives it one.
  def write_project(files, calls, members: {})
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    all = files.merge("0_base.rb" => base_source)
    declared = all.values.flat_map { |body| body.scan(/^\s*(class|module) ([\w:]+)( < \w+)?/) }.uniq
    sig = declared.map { |kind, name, sup| "#{kind} #{name}#{sup}\n#{members[name]}end\n" }.join
    File.write(File.join("sig", "types.rbs"), sig)
    all.each { |name, body| File.write(File.join("lib", name), body) }
    File.write(File.join("lib", "use.rb"), "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  def base_source = "class Base\n  def self.bar = 1\nend\nmodule Xq\n  def bar = \"X\"\nend\n"

  def concern(name, body = "") = "module #{name}\n  extend ActiveSupport::Concern\n  def own = 1\n#{body}end\n"

  def reopening(name, hook, body) = "module #{name}\n#{block(hook, body)}end\n"

  def member = "  def own: () -> Integer\n"

  def block(hook, body) = "  #{hook} do\n#{body}  end\n"

  def includer(name, mixin, superclass: " < Base", edge: "include")
    "class #{name}#{superclass}\n  #{edge} #{mixin}\nend\n"
  end

  describe "an included or prepended block in a reopening without the extend" do
    # Ruby answers "X": `Ci` is a concern when `b_reopen.rb` runs. Loaded first, the reopening raises ArgumentError
    # (`Module#included` takes the includer), so no running program has `Ki` without the extend.
    it "answers the extended module in a cross-file reopening" do
      write_project({ "a_ci.rb" => concern("Ci"), "b_reopen.rb" => reopening("Ci", "included", "    extend Xq\n"),
                      "k.rb" => includer("Ki", "Ci") }, ["Ki.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    it "answers the extended module in a same-file reopening" do
      source = "#{concern('Ci')}module Ci\n#{block('included', "    extend Xq\n")}end\n"
      write_project({ "a_ci.rb" => source, "k.rb" => includer("Ki", "Ci") }, ["Ki.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    # Ruby answers "X": a prepended concern runs its `prepended` block in the prepender's class body.
    it "answers the extended module of a reopening's prepended block" do
      write_project({ "a_ci.rb" => concern("Ci"),
                      "b_reopen.rb" => "module Ci\n#{block('prepended', "    extend Xq\n")}end\n",
                      "k.rb" => includer("Ki", "Ci", edge: "prepend") }, ["Ki.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
    end

    it "still reports a class-side name no module or class provides" do
      write_project({ "a_ci.rb" => concern("Ci"), "b_reopen.rb" => reopening("Ci", "included", "    extend Xq\n"),
                      "k.rb" => includer("Ki", "Ci") }, ["Ki.zork"], members: { "Ki" => member })
      expect(undefined_messages).to eq(["undefined method `zork' for singleton(Ki)"])
    end

    # Ruby answers 1: `Cn`'s own `included` takes the block and runs nothing, so `Kn` is not extended.
    it "does not read the block of a module no file declares a concern" do
      dsl = "module Cn\n  def self.included(base = nil, &) = nil\nend\n"
      write_project({ "a_cn.rb" => dsl, "b_reopen.rb" => "module Cn\n#{block('included', "    extend Xq\n")}end\n",
                      "k.rb" => includer("Kn", "Cn") }, ["Kn.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end

    # Ruby answers 1: the macro `my_attr` of `Cm::ClassMethods`, called in the reopening's block, defines `foo`.
    it "reads a macro call in the reopening's block as the includer's" do
      macro = concern("Cm", block("class_methods", "    def my_attr(n) = define_method(n) { 1 }\n"))
      write_project({ "a_cm.rb" => macro, "b_reopen.rb" => "module Cm\n#{block('included', "    my_attr :foo\n")}end\n",
                      "k.rb" => includer("Km", "Cm", superclass: "") }, ["Km.new.foo.zork"])
      expect(undefined_messages).to be_empty
    end

    # Ruby raises NoMethodError: `Kn3` has no `my_attr`, so the guarded call defines nothing. Read as the includer's
    # extend, the reopening's `Mx` would open `Kn3` to any name.
    it "does not read the extend of a module no file declares a concern as the includer's macros" do
      dsl = "module Mx\n  def my_attr(n) = define_method(n) { 1 }\nend\n" \
            "module Cn3\n  def self.included(base = nil, &) = nil\nend\n"
      write_project({ "a_cn.rb" => dsl, "b_reopen.rb" => reopening("Cn3", "included", "    extend Mx\n"),
                      "k.rb" => "class Kn3\n  include Cn3\n  my_attr :foo if name.nil?\nend\n" }, ["Kn3.new.foo"])
      expect(undefined_messages).to eq(["undefined method `foo' for Kn3"])
    end

    # Ruby raises NoMethodError: `Cn2`'s own `included` takes the block, so neither the extend nor the macro runs.
    it "does not read a macro call in the block of a module no file declares a concern" do
      dsl = "module Mx\n  def my_attr(n) = define_method(n) { 1 }\nend\n" \
            "module Cn2\n  def self.included(base = nil, &) = nil\nend\n"
      write_project({ "a_cn.rb" => dsl,
                      "b_reopen.rb" => "module Cn2\n#{block('included', "    extend Mx\n    my_attr :foo\n")}end\n",
                      "k.rb" => includer("Kn2", "Cn2", superclass: "") }, ["Kn2.new.foo"])
      expect(undefined_messages).to eq(["undefined method `foo' for Kn2"])
    end
  end

  describe "a def self.x in an included or prepended block" do
    let(:defining) { block("included", "    def self.made = 3\n") }

    it "answers the def on a direct includer of a single-file concern" do
      write_project({ "a_cd.rb" => concern("Cd", defining), "k.rb" => includer("Kd", "Cd", superclass: "") },
                    ["Kd.made.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 3"])
    end

    it "answers the def of a reopening's block" do
      write_project({ "a_cd.rb" => concern("Cd"), "b_reopen.rb" => "module Cd\n#{defining}end\n",
                      "k.rb" => includer("Kd", "Cd", superclass: "") }, ["Kd.made.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 3"])
    end

    it "answers the def of a prepended block on a prepender" do
      write_project({ "a_cd.rb" => concern("Cd", block("prepended", "    def self.made = 3\n")),
                      "k.rb" => includer("Kd", "Cd", superclass: "", edge: "prepend") }, ["Kd.made.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 3"])
    end

    it "answers the def on a subclass and on the final includer of a dependent concern" do
      outer = concern("Co", "  include Cd\n")
      write_project({ "a_cd.rb" => concern("Cd", defining), "b_co.rb" => outer,
                      "k.rb" => "#{includer('Kd', 'Cd', superclass: '')}class Sd < Kd\nend\n",
                      "l.rb" => includer("Ko", "Co", superclass: "") },
                    ["Sd.made.zork", "Ko.made.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 3"] * 2)
    end

    # Ruby answers :blk ahead of the superclass's 1 and of `ClassMethods`' :cm: the block defines on `Kd`'s own
    # singleton class.
    it "answers the def ahead of the concern's ClassMethods and the superclass" do
      body = block("class_methods", "    def bar = :cm\n") + block("included", "    def self.bar = :blk\n")
      write_project({ "a_cd.rb" => concern("Cd", body), "k.rb" => includer("Kd", "Cd") }, ["Kd.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for :blk"])
    end

    # Ruby answers :cm: `prepend_features` prepends `ClassMethods` to the singleton class the block defines on.
    it "answers a prepended concern's ClassMethods ahead of its block's def" do
      body = block("class_methods", "    def bar = :cm\n") + block("prepended", "    def self.bar = :blk\n")
      write_project({ "a_cd.rb" => concern("Cd", body), "k.rb" => includer("Kd", "Cd", edge: "prepend") },
                    ["Kd.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for :cm"])
    end

    # Ruby answers 1: a receiverless `def` in the block defines an instance method of the includer.
    it "leaves a receiverless def of the block off the class side" do
      write_project({ "a_cd.rb" => concern("Cd", block("included", "    def bar = :inst\n")),
                      "k.rb" => includer("Kd", "Cd") }, ["Kd.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end

    # Ruby answers 1: the macro the block defines on `Kd`'s singleton class defines `foo`.
    it "reads a macro the block defines as the includer's" do
      macro = block("included", "    def self.my_attr(n) = define_method(n) { 1 }\n")
      write_project({ "a_cd.rb" => concern("Cd", macro),
                      "k.rb" => "class Kd\n  include Cd\n  my_attr :foo\nend\n" }, ["Kd.new.foo.zork"])
      expect(undefined_messages).to be_empty
    end

    it "still reports a class-side name no module or class provides" do
      write_project({ "a_cd.rb" => concern("Cd", defining), "k.rb" => includer("Kd", "Cd", superclass: "") },
                    ["Kd.nope"], members: { "Kd" => member })
      expect(undefined_messages).to eq(["undefined method `nope' for singleton(Kd)"])
    end

    # Ruby raises NoMethodError: `Cn`'s own `included` takes the block and defines nothing.
    it "does not answer the def for a module no file declares a concern" do
      dsl = "module Cn\n  def self.included(base = nil, &) = nil\n#{defining}end\n"
      write_project({ "a_cn.rb" => dsl, "k.rb" => includer("Kn", "Cn", superclass: "") }, ["Kn.made"])
      expect(undefined_messages).to eq(["undefined method `made' for singleton(Kn)"])
    end
  end

  describe "a concern that extends itself through self or send" do
    let(:class_methods) { block("class_methods", "    def bar = \"s\"\n") }
    let(:extending) { block("included", "    extend Xq\n") }

    {
      "self.extend" => "self.extend ActiveSupport::Concern",
      "send(:extend, …)" => "send(:extend, ActiveSupport::Concern)",
      "self.public_send(:extend, …)" => "self.public_send(:extend, ::ActiveSupport::Concern)"
    }.each do |form, line|
      it "reads the class_methods block of a #{form} concern" do
        write_project({ "a_cs.rb" => "module Cs\n  #{line}\n#{class_methods}end\n", "k.rb" => includer("Ks", "Cs") },
                      ["Ks.bar.zork"])
        expect(undefined_messages).to eq(["undefined method `zork' for \"s\""])
      end

      it "reads the included block of a #{form} concern" do
        write_project({ "a_cs.rb" => "module Cs\n  #{line}\n#{extending}end\n", "k.rb" => includer("Ks", "Cs") },
                      ["Ks.bar.zork"])
        expect(undefined_messages).to eq(["undefined method `zork' for \"X\""])
      end

      it "reads a reopening's blocks of a #{form} concern" do
        write_project({ "a_cs.rb" => "module Cs\n  #{line}\nend\n", "a_ct.rb" => "module Ct\n  #{line}\nend\n",
                        "b_reopen_cs.rb" => "module Cs\n#{class_methods}end\n",
                        "b_reopen_ct.rb" => "module Ct\n#{extending}end\n",
                        "k.rb" => "#{includer('Ks', 'Cs')}#{includer('Kt', 'Ct')}" }, ["Ks.bar.zork", "Kt.bar.zork"])
        expect(undefined_messages).to eq(["undefined method `zork' for \"X\"", "undefined method `zork' for \"s\""])
      end
    end

    # Ruby answers 1: `send(:include, …)` mixes Concern's methods into the module's instances, so `Cs` is no concern
    # and its `class_methods` is its own DSL.
    it "does not read a module that sends include of Concern" do
      own = "module Cs\n  def self.class_methods(&) = nil\n  send(:include, ActiveSupport::Concern)\n#{class_methods}end\n"
      write_project({ "a_cs.rb" => own, "k.rb" => includer("Ks", "Cs") }, ["Ks.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end

    it "still reports a class-side name no module or class provides" do
      write_project({ "a_cs.rb" => "module Cs\n  self.extend ActiveSupport::Concern\n#{class_methods}end\n",
                      "k.rb" => includer("Ks", "Cs") }, ["Ks.zork"], members: { "Ks" => member })
      expect(undefined_messages).to eq(["undefined method `zork' for singleton(Ks)"])
    end

    # Ruby answers 1: `Cs`'s body extends `Ot` with Concern, not `Cs` itself, so `Cs` is no concern and its
    # `class_methods` is its own DSL.
    it "does not read a module whose body extends another module with Concern" do
      extends = "  Ot.send(:extend, ActiveSupport::Concern)\n  Ot.extend ActiveSupport::Concern\n"
      other = "module Ot\nend\nmodule Cs\n  def self.class_methods(&) = nil\n#{extends}#{class_methods}end\n"
      write_project({ "a_cs.rb" => other, "k.rb" => includer("Ks", "Cs") }, ["Ks.bar.zork"])
      expect(undefined_messages).to eq(["undefined method `zork' for 1"])
    end
  end
end
