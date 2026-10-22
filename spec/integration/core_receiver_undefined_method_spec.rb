# frozen_string_literal: true

# Issue #1722 — `call.undefined-method` on core-class receivers (a literal, a plain `Integer` / `String`, and a union
# of one class's literals) where the program gives the receiver the method in a way the RBS lookup cannot see:
#
# 1. a source `method_missing` on the class or an RBS ancestor;
# 2. `C.include(M)` / `C.prepend(M)` / `C.send(:include, M)` outside the class body, or a mixin of an RBS ancestor;
# 3. singleton methods given to the object a local holds (`s.extend(M)`, `define_singleton_method`,
#    `s.singleton_class.class_eval`, `s.instance_eval { def }`, `class << s`);
# 4. a value typed `String` through a signature that holds a project subclass defining the method;
# 5. a mixed-in project module that extends a DSL Rigor cannot read, or hands a macro the name (#2094).
#
# Each row runs the fixture under Ruby and under `rigor check`. Every call is a `t(:label) { ... }` line, so a firing
# maps back to its label. A label Ruby answers in some world (an `env` the row lists) must stay silent; a label Ruby
# raises on in every world must fire, unless the row lists it under `declines` (a reading the rule makes
# conservatively). The helper carries a `call.wrong-arity` sentinel in a method Ruby never calls, so a run that
# analysed nothing cannot pass; most rows also carry an undefined-method control (a `ctl_` label).

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "call.undefined-method on core receivers the program extends (#1722)" do
  helper = <<~'RUBY'
    def t(label)
      result = yield
      puts "#{label}: OK #{result.inspect}"
    rescue NoMethodError
      puts "#{label}: NoMethodError"
    end

    def sentinel = 1.succ(1)
  RUBY

  # Issue #2094 — a gem DSL Rigor has no RBS for, kept outside `lib/` so the analysis never sees it.
  some_gem = <<~RUBY
    module SomeGem
      module Dsl
        def dsl_method(name) = define_method(name) { 1 }
        def self.extended(base) = base.define_method(:from_hook) { 2 }
      end
    end
  RUBY

  rows = {
    "a method_missing on the class, with respond_to_missing?" => {
      "main.rb" => <<~RUBY
        class Integer
          def method_missing(*) = 1
          def respond_to_missing?(*) = true
        end
        #{helper}
        t(:lit) { 1.zzz }
        t(:plain) { Integer("1").zzz }
        t(:union) { (ARGV.empty? ? 1 : 2).zzz }
        t(:ctl_str) { "a".zzz }
      RUBY
    },
    "a method_missing on the class without respond_to_missing?" => {
      "main.rb" => <<~RUBY
        class Integer
          def method_missing(*) = 1
        end
        #{helper}
        t(:lit) { 1.zzz }
        t(:union) { (ARGV.empty? ? 1 : 2).zzz }
        t(:ctl_str) { "a".zzz }
      RUBY
    },
    "a respond_to_missing? alone" => {
      "main.rb" => <<~RUBY
        class Integer
          def respond_to_missing?(*) = true
        end
        #{helper}
        t(:ctl_lit) { 1.zzz }
      RUBY
    },
    "a method_missing on Comparable" => {
      "main.rb" => <<~RUBY
        module Comparable
          def method_missing(*) = 1
        end
        #{helper}
        t(:lit) { 1.zzz }
        t(:str) { "a".zzz }
        t(:ctl_array) { [1].zzz }
      RUBY
    },
    "a method_missing on Numeric" => {
      "main.rb" => <<~RUBY
        class Numeric
          def method_missing(*) = 1
        end
        #{helper}
        t(:lit) { 1.zzz }
        t(:float) { 1.5.zzz }
        t(:ctl_str) { "a".zzz }
      RUBY
    },
    "a method_missing on Object, which a class object reaches too" => {
      "main.rb" => <<~RUBY
        class Object
          def method_missing(*) = 1
        end
        #{helper}
        t(:lit) { 1.zzz }
        t(:str) { "a".zzz }
        t(:cls) { Integer.zzz }
      RUBY
    },
    "a method_missing on Kernel" => {
      "main.rb" => <<~RUBY
        module Kernel
          def method_missing(*) = 1
        end
        #{helper}
        t(:lit) { 1.zzz }
        t(:str) { "a".zzz }
      RUBY
    },
    "a method_missing on BasicObject" => {
      "main.rb" => <<~RUBY
        class BasicObject
          def method_missing(*) = 1
        end
        #{helper}
        t(:lit) { 1.zzz }
        t(:str) { "a".zzz }
      RUBY
    },
    "a method_missing in a module the class includes" => {
      "main.rb" => <<~RUBY
        module Hook
          def method_missing(*) = 1
        end
        class Integer
          include Hook
        end
        #{helper}
        t(:lit) { 1.zzz }
        t(:ctl_str) { "a".zzz }
      RUBY
    },
    "a method_missing in another file" => {
      "lib.rb" => <<~RUBY,
        class Integer
          def method_missing(*) = 1
        end
      RUBY
      "main.rb" => <<~RUBY
        require_relative "lib"
        #{helper}
        t(:lit) { 1.zzz }
        t(:union) { (ARGV.empty? ? 1 : 2).zzz }
        t(:ctl_str) { "a".zzz }
      RUBY
    },
    "a method_missing under an if" => {
      env: [{}, { "HOOK" => "1" }],
      "main.rb" => <<~RUBY
        class Integer
          if ENV["HOOK"]
            def method_missing(*) = 1
          end
        end
        #{helper}
        t(:lit) { 1.zzz }
        t(:ctl_str) { "a".zzz }
      RUBY
    },
    "Integer.include(Ext) at the top level" => {
      "main.rb" => <<~RUBY
        module Ext
          def zzz_incl = 1
        end
        Integer.include(Ext)
        #{helper}
        t(:lit) { 1.zzz_incl }
        t(:plain) { Integer("1").zzz_incl }
        t(:union) { (ARGV.empty? ? 1 : 2).zzz_incl }
        t(:ctl_lit) { 1.nope }
        t(:ctl_str) { "a".zzz_incl }
      RUBY
    },
    "Integer.include(Ext) in a method that may not run" => {
      env: [{}, { "SETUP" => "1" }],
      "main.rb" => <<~RUBY
        module Ext
          def zzz_incl = 1
        end
        def setup = Integer.include(Ext)
        setup if ENV["SETUP"]
        #{helper}
        t(:lit) { 1.zzz_incl }
        t(:ctl_lit) { 1.nope }
      RUBY
    },
    "Integer.include(Ext) in another file" => {
      "lib.rb" => <<~RUBY,
        module Ext
          def zzz_incl = 1
        end
        Integer.include(Ext)
      RUBY
      "main.rb" => <<~RUBY
        require_relative "lib"
        #{helper}
        t(:lit) { 1.zzz_incl }
        t(:union) { (ARGV.empty? ? 1 : 2).zzz_incl }
        t(:ctl_lit) { 1.nope }
      RUBY
    },
    "Integer.prepend(Ext)" => {
      "main.rb" => <<~RUBY
        module Ext
          def zzz_pre = 1
        end
        Integer.prepend(Ext)
        #{helper}
        t(:lit) { 1.zzz_pre }
        t(:union) { (ARGV.empty? ? 1 : 2).zzz_pre }
        t(:ctl_lit) { 1.nope }
      RUBY
    },
    "Integer.send(:include, Ext)" => {
      "main.rb" => <<~RUBY
        module Ext
          def zzz_send = 1
        end
        Integer.send(:include, Ext)
        #{helper}
        t(:lit) { 1.zzz_send }
        t(:union) { (ARGV.empty? ? 1 : 2).zzz_send }
        t(:ctl_lit) { 1.nope }
      RUBY
    },
    "String.class_eval { def }" => {
      "main.rb" => <<~RUBY
        String.class_eval { def zzz_ce = 1 }
        #{helper}
        t(:lit) { "a".zzz_ce }
        t(:union) { (ARGV.empty? ? "a" : "b").zzz_ce }
        t(:ctl_lit) { "a".nope }
      RUBY
    },
    "Comparable.include(Ext)" => {
      "main.rb" => <<~RUBY
        module Ext
          def zzz_cmp = 1
        end
        Comparable.include(Ext)
        #{helper}
        t(:lit) { 1.zzz_cmp }
        t(:str) { "a".zzz_cmp }
        t(:ctl_array) { [1].zzz_cmp }
      RUBY
    },
    "an include into an unrelated class" => {
      "main.rb" => <<~RUBY
        module Ext
          def zzz_incl = 1
        end
        Array.include(Ext)
        #{helper}
        t(:arr) { [1].zzz_incl }
        t(:ctl_str) { "a".zzz_incl }
        t(:ctl_int) { 1.zzz }
      RUBY
    },
    "extend on the receiver local" => {
      "main.rb" => <<~RUBY
        module M
          def m = 1
        end
        #{helper}
        s = ARGV.empty? ? "a" : "b"
        s.extend(M)
        t(:union) { s.m }
        l = "a"
        l.extend(M)
        t(:lit) { l.m }
        pl = String.new("x")
        pl.extend(M)
        t(:plain) { pl.m }
        t(:ctl_other) { "c".m }
      RUBY
    },
    "extend on the receiver local under an if" => {
      env: [{}, { "EXT" => "1" }],
      "main.rb" => <<~RUBY
        module M
          def m = 1
        end
        #{helper}
        s = "a"
        s.extend(M) if ENV["EXT"]
        t(:lit) { s.m }
        t(:ctl_other) { "c".m }
      RUBY
    },
    "extend on a different local" => {
      "main.rb" => <<~RUBY
        module M
          def m = 1
        end
        #{helper}
        s = "a"
        o = "b"
        o.extend(M)
        t(:ctl_lit) { s.m }
      RUBY
    },
    "dup and clone of an extended local" => {
      # `clone` copies the singleton class and `dup` does not. `s = s.dup` keeps the name the extend was written on,
      # which the rule reads as extended.
      declines: %w[self_dup],
      "main.rb" => <<~RUBY
        module M
          def m = 1
        end
        #{helper}
        s = "a"
        s.extend(M)
        d = s.dup
        t(:ctl_dup) { d.m }
        k = s.clone
        t(:clone) { k.m }
        s = s.dup
        t(:self_dup) { s.m }
      RUBY
    },
    "the other singleton spellings on a local" => {
      "main.rb" => <<~RUBY
        #{helper}
        v = "a"
        v.define_singleton_method(:vv) { 1 }
        t(:dsm) { v.vv }
        t(:ctl_dsm) { v.vx }
        w = "a"
        w.singleton_class.class_eval { def ww = 1 }
        t(:sc_eval) { w.ww }
        z = "a"
        z.instance_eval { def zz = 1 }
        t(:ie_def) { z.zz }
        c = "a"
        class << c
          def cc = 1
        end
        t(:sclass) { c.cc }
        g = "a"
        g.instance_eval("def gg = 1")
        t(:ie_string) { g.gg }
        f = "a"
        f.instance_eval { @x = 1 }
        t(:ctl_ie) { f.zz }
      RUBY
    },
    "a hook in a project module mixed into Integer" => {
      "main.rb" => <<~RUBY
        module Hooky
          def self.included(base)
            base.class_eval { def dyn = 1 }
            base.send(:define_method, :dyn2) { 2 }
          end
        end
        Integer.include(Hooky)
        #{helper}
        t(:dyn) { 1.dyn }
        t(:dyn2) { (ARGV.empty? ? 1 : 2).dyn2 }
        t(:ctl_str) { "a".dyn }
      RUBY
    },
    "a hook in a project module included in the class body" => {
      "main.rb" => <<~RUBY
        module Hooky2
          def self.included(base)
            base.class_eval { def dyn = 1 }
          end
        end
        class Integer
          include Hooky2
        end
        #{helper}
        t(:dyn) { 1.dyn }
        t(:ctl_str) { "a".dyn }
      RUBY
    },
    "an open-surface module mixed into Object, Kernel or BasicObject" => {
      # A hook, a `"*"` mixin or a Concern opens a mixin's surface on any other ancestor; on these roots only a module
      # that defines the name answers (#1697), so every call here fires as Ruby raises.
      "vendor/concern.rb" => <<~RUBY,
        module ActiveSupport
          module Concern
          end
        end
      RUBY
      "main.rb" => <<~RUBY
        require_relative "../vendor/concern"
        module Helpers
          module ClassMethods
          end

          def self.included(base) = base.extend(ClassMethods)
        end
        module Starred
          MODS = [Comparable].freeze
          MODS.each { |m| include m }
        end
        module Concerned
          extend ActiveSupport::Concern
        end
        Object.include(Helpers)
        Kernel.include(Starred)
        BasicObject.include(Concerned)
        #{helper}
        t(:ctl_lit) { 1.nope }
        t(:ctl_str) { "a".nope }
      RUBY
    },
    "a module RBS does not know mixed into Kernel or Object" => {
      "vendor/some_gem.rb" => <<~RUBY,
        module SomeGem
          module Unknown
          end

          module Other
          end
        end
      RUBY
      "main.rb" => <<~RUBY
        require_relative "../vendor/some_gem"
        module Wrapper
          include SomeGem::Unknown
        end
        Kernel.include(Wrapper)
        Object.include(SomeGem::Other)
        #{helper}
        t(:ctl_lit) { 1.nope }
      RUBY
    },
    "an empty project module mixed into Integer" => {
      "main.rb" => <<~RUBY
        module Empty
        end
        Integer.include(Empty)
        #{helper}
        t(:ctl_lit) { 1.dyn }
      RUBY
    },
    "a project module mixed into Kernel and BasicObject" => {
      "main.rb" => <<~RUBY
        module KExt
          def kzz = 1
        end
        module KExt2
          def kzz2 = 1
        end
        module BExt
          def bzz = 1
        end
        Kernel.include(KExt)
        module Kernel
          include KExt2
        end
        BasicObject.include(BExt)
        #{helper}
        t(:kernel) { 1.kzz }
        t(:kernel_body) { "a".kzz2 }
        t(:basic) { (ARGV.empty? ? 1 : 2).bzz }
        t(:ctl_lit) { 1.nope }
      RUBY
    },
    "a module RBS does not know mixed into Comparable" => {
      # The module lives outside the analysed paths, so neither RBS nor the project declares it.
      "vendor/other_gem.rb" => <<~RUBY,
        module OtherGem
          module Mod
            def zzz = 1
          end
        end
      RUBY
      "main.rb" => <<~RUBY
        require_relative "../vendor/other_gem"
        Comparable.include(OtherGem::Mod)
        #{helper}
        t(:str) { "s".zzz }
        t(:ctl_array) { [1].zzz }
      RUBY
    },
    "a project module calling an unknown gem DSL macro, mixed into String" => {
      # Ruby raises on `other`, but a module that extends a DSL Rigor cannot read may define any name.
      declines: %w[other],
      "vendor/some_gem.rb" => some_gem,
      "ext.rb" => <<~RUBY,
        module OnlyExt
          dsl_method :sib
        end
      RUBY
      "main.rb" => <<~RUBY
        require_relative "../vendor/some_gem"
        module OnlyExt
          extend SomeGem::Dsl
          dsl_method :xdyn
        end
        require_relative "ext"
        String.include(OnlyExt)
        # A module with a `def` of its own is a project entry of the chain, not an external one.
        module WithDef
          extend SomeGem::Dsl
          def own = 1
        end
        Array.include(WithDef)
        #{helper}
        t(:named) { "s".xdyn }
        t(:sibling_named) { "s".sib }
        t(:hook) { "s".from_hook }
        t(:other) { "s".other_name }
        t(:def_hook) { [1].from_hook }
        t(:ctl_int) { 1.xdyn }
      RUBY
    },
    "an unknown gem DSL extended under an if" => {
      env: [{}, { "DSL" => "1" }],
      "vendor/some_gem.rb" => some_gem,
      "main.rb" => <<~RUBY
        require_relative "../vendor/some_gem"
        module CondExt
          extend SomeGem::Dsl if ENV["DSL"]
        end
        Symbol.include(CondExt)
        #{helper}
        t(:hook) { :a.from_hook }
        t(:ctl_int) { 1.from_hook }
      RUBY
    },
    "a literal-named macro from a module RBS knows, mixed into Integer" => {
      "main.rb" => <<~RUBY
        require "forwardable"
        module Named
          extend Forwardable
          def_delegators :to_s, :upcase
        end
        Integer.include(Named)
        module NamedDef
          extend Forwardable
          def_delegators :to_s, :downcase
          def own = 1
        end
        Integer.include(NamedDef)
        #{helper}
        t(:named) { 1.upcase }
        t(:def_named) { 1.downcase }
        t(:ctl_not_named) { 1.not_named }
      RUBY
    },
    "an unknown gem DSL in a module mixed into Object" => {
      "vendor/some_gem.rb" => some_gem,
      "main.rb" => <<~RUBY
        require_relative "../vendor/some_gem"
        module TopMac
          extend SomeGem::Dsl
          dsl_method :top_named
        end
        include TopMac
        module TopDef
          extend SomeGem::Dsl
          dsl_method :top_def_named
          def own_top = 1
        end
        include TopDef
        #{helper}
        t(:named) { 1.top_named }
        t(:def_named) { 1.top_def_named }
        t(:ctl_other) { 1.zzz_top }
      RUBY
    },
    "a module extending an unknown gem DSL, mixed into a class object's singleton side" => {
      "vendor/some_gem.rb" => some_gem,
      "main.rb" => <<~RUBY
        require "forwardable"
        require_relative "../vendor/some_gem"
        module Ext2
          extend SomeGem::Dsl
          dsl_method :ext2
        end
        Float.extend(Ext2)
        module Ext3
          extend SomeGem::Dsl
        end
        Symbol.singleton_class.include(Ext3)
        module Plain2
          def pl = 1
        end
        Rational.extend(Plain2)
        class Rational
          def inst_only = 1
        end
        module Named4
          extend Forwardable
          def_delegators :to_s, :upcase
        end
        Complex.extend(Named4)
        #{helper}
        t(:named) { Float.ext2 }
        t(:hook) { Float.from_hook }
        t(:singleton_class_include) { Symbol.from_hook }
        t(:plain) { Rational.pl }
        t(:ctl_plain_other) { Rational.zzz }
        t(:ctl_instance_only) { Rational.inst_only }
        t(:rbs_extend_named) { Complex.upcase }
        t(:ctl_rbs_extend_other) { Complex.nope }
        t(:ctl_other_class) { Integer.ext2 }
      RUBY
    },
    "a singleton mixin the indexer cannot record, or records from class << self" => {
      # `singleton_class.include` inside `class << self` reaches the singleton's own singleton; the walk taints
      # Float's extend side for it, so `Float.si` declines although Ruby raises.
      declines: %w[up_level],
      "main.rb" => <<~RUBY
        module Plain5
          def pl5 = 1
        end
        module SI5
          def si5 = 1
        end
        m = Plain5
        Integer.extend(m)
        Complex.singleton_class.include(SI5, m)
        module SelfExt
          def se = 1
          Rational.extend(self)
        end
        class Holder
          class << self
            String.extend(Plain5)
          end
        end
        class Float
          class << self
            singleton_class.include(SI5)
          end
        end
        #{helper}
        t(:local_argument) { Integer.pl5 }
        t(:mixed_arguments) { Complex.pl5 }
        t(:self_argument) { Rational.se }
        t(:in_class_singleton_body) { String.pl5 }
        t(:ctl_in_class_singleton_body) { String.zzz5 }
        t(:up_level) { Float.si5 }
        t(:ctl_untouched) { Range.zzz5 }
      RUBY
    },
    "an open module extended onto Object, read only for the names it defines" => {
      "vendor/some_gem.rb" => some_gem,
      "main.rb" => <<~RUBY
        require_relative "../vendor/some_gem"
        module OpenMod
          extend SomeGem::Dsl
          dsl_method :obj_named
        end
        Object.extend(OpenMod)
        #{helper}
        t(:named) { Float.obj_named }
        t(:ctl_other) { Float.zzz_obj }
      RUBY
    },
    "an unknown module included into Module, which is not a module's own extend" => {
      "vendor/some_gem.rb" => some_gem,
      "main.rb" => <<~RUBY
        require_relative "../vendor/some_gem"
        class Module
          include SomeGem::Dsl
        end
        module Plain3
          def own3 = 1
        end
        String.include(Plain3)
        #{helper}
        t(:own) { "s".own3 }
        t(:ctl_other) { "s".zzz_mod }
      RUBY
    },
    "an extend chain deeper than the resolution budget" => {
      # Past the budget the chain may hold an open module, so every name declines.
      declines: %w[deep_instance deep_singleton],
      "deep.rb" => (0..101).reverse_each.map do |i|
        "module Deep#{i}\n#{"  include Deep#{i + 1}\n" if i < 101}end\n"
      end.join,
      "main.rb" => <<~RUBY
        require_relative "deep"
        module DeepExt
          extend Deep0
          def own = 1
        end
        String.include(DeepExt)
        Float.extend(Deep0)
        #{helper}
        t(:deep_instance) { "s".zzz_deep }
        t(:deep_singleton) { Float.zzz_deep }
      RUBY
    },
    "literal and shape receivers beside project subclasses" => {
      # A value built from a literal is exactly its class. A local holding an interpolated String types as plain
      # `String` with no origin, so it declines.
      declines: %w[interp_local],
      "subs.rb" => <<~RUBY,
        class HSub < Hash
          def hsub = 1
        end
        class ASub < Array
          def asub = 1
        end
        class SSub < String
          def ssub = 1
        end
      RUBY
      "main.rb" => <<~RUBY
        require_relative "subs"
        #{helper}
        t(:ctl_hash) { { a: 1 }.hsub }
        h = {}
        t(:ctl_hash_local) { h.hsub }
        t(:ctl_array) { [1, 2].asub }
        t(:ctl_empty) { [].asub }
        t(:ctl_map) { [1, 2].map { |x| x }.asub }
        t(:ctl_interp) { "a\#{ARGV.size}b".ssub }
        i = "a\#{ARGV.size}b"
        t(:interp_local) { i.ssub }
      RUBY
    },
    "a union of two classes" => {
      # Each arm is asked: one arm answering keeps the union silent, as Ruby answers in one world.
      env: [{}, { "STR" => "1" }],
      "main.rb" => <<~RUBY
        class Integer
          def method_missing(*) = 1
        end
        module M
          def m = 1
        end
        #{helper}
        t(:mm) { (ENV["STR"] ? "a" : 1).zzz }
        u = ENV["STR"] ? [1] : "a"
        u.extend(M)
        t(:extend) { u.m }
        t(:ctl_union) { (ENV["STR"] ? "a" : [1]).zzz }
      RUBY
    },
    "a String subclass returned through a String signature" => {
      # The union's `""` arm raises and its `String` arm, a `MyStr`, answers: not every arm lacks the method.
      env: [{}, { "ARG" => "1" }],
      "my_str.rb" => <<~RUBY,
        class MyStr < String
          def zzz_sub = 1
        end
      RUBY
      "box.rbs" => <<~RBS,
        class Box
          def make: () -> String
        end
      RBS
      "main.rb" => <<~RUBY
        require_relative "my_str"
        class Box
          def make = MyStr.new("q")
        end
        #{helper}
        m = Box.new.make
        t(:plain) { m.zzz_sub }
        t(:union) { (ENV["ARG"] ? Box.new.make : "").zzz_sub }
        t(:ctl_none) { m.nope_none }
        t(:ctl_lit) { "a".zzz_sub }
      RUBY
    },
    "a String subclass with a method_missing returned through a String signature" => {
      "my_str.rb" => <<~RUBY,
        class MyStr < String
          def method_missing(*) = 1
        end
      RUBY
      "box.rbs" => <<~RBS,
        class Box
          def make: () -> String
        end
      RBS
      "main.rb" => <<~RUBY
        require_relative "my_str"
        class Box
          def make = MyStr.new("q")
        end
        #{helper}
        t(:plain) { Box.new.make.anything }
        t(:ctl_lit) { "a".anything }
      RUBY
    }
  }

  around do |example|
    Dir.mktmpdir("rigor-core-receiver-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write_fixture(files)
    FileUtils.mkdir_p(%w[lib sig])
    files.each do |name, source|
      path = if name.include?("/") then name
             elsif name.end_with?(".rbs") then File.join("sig", name)
             else File.join("lib", name)
             end
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end
  end

  # `[undefined-method labels, wrong-arity sentinel count]`.
  def rigor_firings
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    source = File.readlines(File.join("lib", "main.rb"))
    diagnostics = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
                  .diagnostics
    undefined = diagnostics.select { |diagnostic| diagnostic.qualified_rule == "call.undefined-method" }
    labels = undefined.map do |diagnostic|
      source[diagnostic.line - 1][/t\(:(\w+)\)/, 1] || "#{File.basename(diagnostic.path)}:#{diagnostic.line}"
    end
    [labels, diagnostics.count { |diagnostic| diagnostic.qualified_rule == "call.wrong-arity" }]
  end

  # `{label => [outcome per world]}`.
  def ruby_outcomes(worlds)
    worlds.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |env, out|
      stdout, stderr, status = RubyRun.capture("-e", "ENV.update(#{env.inspect}); load 'lib/main.rb'")
      raise "Ruby failed on the fixture: #{stderr}" unless status.success?

      stdout.scan(/^(\w+): (OK|NoMethodError)/) { |label, outcome| out[label] << outcome }
    end
  end

  rows.each do |title, row|
    it "answers as Ruby does for #{title}" do
      write_fixture(row.reject { |key, _| key.is_a?(Symbol) })
      outcomes = ruby_outcomes(row.fetch(:env, [{}]))
      always_raises = outcomes.select { |_, results| results.all?("NoMethodError") }.keys
      labels, sentinels = rigor_firings

      expect(outcomes.keys.grep(/\Actl_/) - always_raises).to eq([])
      expect(sentinels).to eq(1)
      expect(labels).to match_array(always_raises - row.fetch(:declines, []))
    end
  end
end
