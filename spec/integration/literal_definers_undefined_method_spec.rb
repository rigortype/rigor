# frozen_string_literal: true

# Issue #2975 — the definers #2972 (#2901) left reporting `call.undefined-method`: a literal
# `send(:define_method, :x)` and `define_singleton_method(:x)`, which now record the method, a literal
# `Other.define_method(:x)`, which records on `Other` and not the enclosing class, and the class macros #2972 did not
# read — one patched onto `Module`, one defined in a `singleton_class.class_eval` body, one that mixes in a
# `Module.new { define_method(x) }` — plus the side of a macro's definer entry. Every shape has a same-file and a
# cross-file row, and each row's Ruby behaviour was witnessed on Ruby 4.0.5.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Literal definers and further class macros, and call.undefined-method (#2975)" do
  # Every top-level class and module the sources write gets an empty `sig/` declaration (core ones excepted), unless
  # `sig:` gives the declarations.
  def write_project(source, calls, extra_files: {}, sig: nil)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    declared = ([source] + extra_files.values).flat_map { |body| body.scan(/^(class|module) (\w+)/) }.uniq
    declared = declared.reject { |_, name| %w[Module Class Object Kernel BasicObject].include?(name) }
    sig ||= declared.map { |kind, name| "#{kind} #{name}\nend\n" }.join
    File.write(File.join("sig", "types.rbs"), sig)
    File.write(File.join("lib", "defs.rb"), source)
    extra_files.each { |name, body| File.write(File.join("lib", name), body) }
    File.write(File.join("lib", "caller.rb"), "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  around do |example|
    Dir.mktmpdir("rigor-literal-definers-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def definer_body = "n.each { |x| define_method(x) { x } }"

  describe "send(:define_method, :x) on self" do
    it "records the instance method, and keeps reporting another name" do
      write_project("class Snd\n  send(:define_method, :sl) { 1 }\nend\n", %w[Snd.new.sl Snd.new.zz Snd.sl])
      expect(undefined_messages).to eq(["undefined method `sl' for singleton(Snd)", "undefined method `zz' for Snd"])
    end

    it "records the method when another file reopens the class with the call" do
      write_project("class Snd2\nend\n", %w[Snd2.new.sm Snd2.new.zz],
                    extra_files: { "reopen.rb" => "class Snd2\n  __send__(:define_method, :sm) { 1 }\nend\n" })
      expect(undefined_messages).to eq(["undefined method `zz' for Snd2"])
    end

    it "records a singleton method from a class << self body" do
      write_project("class Snd3\n  class << self\n    send(:define_method, :cs) { 1 }\n  end\nend\n",
                    %w[Snd3.cs Snd3.new.cs])
      expect(undefined_messages).to eq(["undefined method `cs' for Snd3"])
    end
  end

  describe "define_singleton_method(:x) on self" do
    it "records the class object's method, and not an instance method" do
      write_project("class Dsl\n  define_singleton_method(:dl) { 1 }\nend\n", %w[Dsl.dl Dsl.new.dl Dsl.zz])
      expect(undefined_messages).to eq(["undefined method `dl' for Dsl", "undefined method `zz' for singleton(Dsl)"])
    end

    it "records the class object's method when another file reopens the class with the call" do
      write_project("class Dsl2\nend\n", %w[Dsl2.dm],
                    extra_files: { "reopen.rb" => "class Dsl2\n  self.define_singleton_method(:dm) { 1 }\nend\n" })
      expect(undefined_messages).to be_empty
    end

    it "records nothing from a class << self body, where it defines on the singleton's own singleton" do
      write_project("class Dsl3\n  class << self\n    define_singleton_method(:dd) { 1 }\n  end\nend\n", %w[Dsl3.dd])
      expect(undefined_messages).to eq(["undefined method `dd' for singleton(Dsl3)"])
    end

    it "records the eval receiver's method from an instance_eval body, and not the enclosing class's" do
      write_project("class Ie\nend\nclass IeHost\n  Ie.instance_eval { define_singleton_method(:ie) { 1 } }\nend\n",
                    %w[Ie.ie IeHost.ie])
      expect(undefined_messages).to eq(["undefined method `ie' for singleton(IeHost)"])
    end
  end

  describe "define_method(:x) on a constant receiver" do
    it "records on that constant's class, and not on the enclosing one" do
      write_project("class Other\nend\nclass Host\n  Other.define_method(:ol) { 1 }\nend\n",
                    %w[Other.new.ol Host.new.ol])
      expect(undefined_messages).to eq(["undefined method `ol' for Host"])
    end

    it "records on the constant's class declared in another file, from a class << self body too" do
      write_project("class Host2\n  class << self\n    Other2.define_method(:om) { 1 }\n  end\nend\n",
                    %w[Other2.new.om Host2.om Host2.new.om],
                    extra_files: { "other.rb" => "class Other2\nend\n" })
      expect(undefined_messages).to eq(["undefined method `om' for Host2",
                                        "undefined method `om' for singleton(Host2)"])
    end

    it "records on the constant's class from the top level" do
      write_project("class Top\nend\nTop.define_method(:tl) { 1 }\n", %w[Top.new.tl Top.new.zz])
      expect(undefined_messages).to eq(["undefined method `zz' for Top"])
    end

    it "keeps the name on the enclosing class for a receiver that may be self" do
      write_project("class Maybe\n  [self].each { |k| k.define_method(:ks) { 1 } }\nend\n", %w[Maybe.new.ks])
      expect(undefined_messages).to be_empty
    end

    it "records on the eval receiver for a send in another class's class_eval block" do
      write_project("class Ce\nend\nclass CeHost\n  Ce.class_eval { send(:define_method, :ce) { 1 } }\nend\n",
                    %w[Ce.new.ce CeHost.new.ce])
      expect(undefined_messages).to eq(["undefined method `ce' for CeHost"])
    end
  end

  describe "where the literal definer runs" do
    # Guard: a definer under a condition may run, so it counts, as a literal define_method there already did.
    it "counts a definer under an if" do
      write_project("class Cond\n  send(:define_method, :cd) { 1 } if ENV.key?(\"PATH\")\nend\n",
                    %w[Cond.new.cd])
      expect(undefined_messages).to be_empty
    end

    # Guard: the declaration walk does not enter a method body, so this holds without #2975; it pins the Ruby answer.
    it "does not count a definer in a method nothing calls" do
      write_project("class Later\n  def self.later = send(:define_method, :lm) { 1 }\nend\n", %w[Later.new.lm])
      expect(undefined_messages).to eq(["undefined method `lm' for Later"])
    end
  end

  describe "a class macro patched onto Module" do
    let(:patch) { "class Module\n  def my_mod_attr(*n) = #{definer_body}\nend\n" }

    it "opens the instance side of a class whose body calls it, and not its class object" do
      write_project("#{patch}class Mp\n  my_mod_attr :mp\nend\n", %w[Mp.new.mp Mp.mp])
      expect(undefined_messages).to eq(["undefined method `mp' for singleton(Mp)"])
    end

    it "opens a class in another file" do
      write_project("class Mp2\n  my_mod_attr :mq\nend\n", %w[Mp2.new.mq], extra_files: { "patch.rb" => patch })
      expect(undefined_messages).to be_empty
    end

    # Guard: no definer entry is recorded for a macro that defines nothing; this pins the reporting side.
    it "reads a macro patched onto Object, Kernel or Class the same way" do
      patches = "class Object\n  def my_o_attr(*n) = #{definer_body}\nend\n" \
                "module Kernel\n  def my_k_attr(*n) = #{definer_body}\nend\n" \
                "class Class\n  def my_cl_attr(*n) = #{definer_body}\nend\n"
      write_project("class Ob\n  my_o_attr :ob\nend\nclass Ke\n  my_k_attr :ke\nend\nclass Cl\n  my_cl_attr :cl\nend\n",
                    %w[Ob.new.ob Ke.new.ke Cl.new.cl], extra_files: { "patch.rb" => patches })
      expect(undefined_messages).to be_empty
    end

    it "opens a class for a macro patched onto BasicObject" do
      write_project("class Bo\n  my_b_attr :bo\nend\n", %w[Bo.new.bo],
                    extra_files: { "patch.rb" => "class BasicObject\n  def my_b_attr(*n) = #{definer_body}\nend\n" })
      expect(undefined_messages).to be_empty
    end

    it "does not open a class that only calls a Module macro defining nothing" do
      write_project("class Module\n  def my_mod_attr(*n) = n\nend\nclass Mp3\n  my_mod_attr :mr\nend\n", %w[Mp3.new.mr])
      expect(undefined_messages).to eq(["undefined method `mr' for Mp3"])
    end
  end

  # The concern module has a `sig/` declaration in every row: without one, #2094's hook rule already opens an
  # includer on every name.
  describe "a macro an included hook extends onto the class" do
    let(:concern) do
      "module Cn\n  def self.included(base) = base.extend(ClassMethods)\n  module ClassMethods\n    " \
        "def my_c_attr(*n) = #{definer_body}\n  end\nend\n"
    end

    it "opens the instance side of the includer" do
      write_project("#{concern}class Cu\n  include Cn\n  my_c_attr :cu\nend\n", %w[Cu.new.cu])
      expect(undefined_messages).to be_empty
    end

    it "opens an includer in another file" do
      write_project("class Cu2\n  include Cn\n  my_c_attr :cv\nend\n", %w[Cu2.new.cv],
                    extra_files: { "cn.rb" => concern })
      expect(undefined_messages).to be_empty
    end

    it "opens the includer when the sig declares the hook and the nested ClassMethods" do
      sig = "module Cn\n  def self.included: (untyped base) -> void\n  module ClassMethods\n    " \
            "def my_c_attr: (*Symbol n) -> Array[Symbol]\n  end\nend\nclass Cu3\n  include Cn\nend\n"
      write_project("#{concern}class Cu3\n  include Cn\n  my_c_attr :cw\nend\n", %w[Cu3.new.cw], sig: sig)
      expect(undefined_messages).to be_empty
    end

    # Guard: pins the reporting side; no removed line of the hook reader makes it pass for the wrong reason.
    it "does not open an includer whose hook extends a module that defines nothing" do
      quiet = "module Cq\n  def self.included(base) = base.extend(ClassMethods)\n  module ClassMethods\n    " \
              "def my_c_attr(*n) = n\n  end\nend\n"
      write_project("#{quiet}class Cu4\n  include Cq\n  my_c_attr :cx\nend\n", %w[Cu4.new.cx])
      expect(undefined_messages).to eq(["undefined method `cx' for Cu4"])
    end
  end

  describe "a class macro defined in a singleton_class.class_eval body" do
    it "opens the instance side of the class whose body calls it" do
      source = "class Sc\n  singleton_class.class_eval do\n    def my_sc_attr(*n) = #{definer_body}\n  end\n  " \
               "my_sc_attr :sc\nend\n"
      write_project(source, %w[Sc.new.sc])
      expect(undefined_messages).to be_empty
    end

    it "reads a constant's singleton_class, defined in another file than the call" do
      macro = "class Sc2\n  Sc2.singleton_class.class_eval { def my_sc2(*n) = #{definer_body} }\nend\n"
      write_project("class Sc2\n  my_sc2 :sd\nend\n", %w[Sc2.new.sd], extra_files: { "macro.rb" => macro })
      expect(undefined_messages).to be_empty
    end

    # Guard: the definer entry is filed per owner, so a sibling's same-named macro stays closed; it pins that.
    it "does not open a class whose singleton_class macro of the same name, in a sibling file, defines nothing" do
      macro = "class Sc3\n  singleton_class.class_eval { def my_sc_attr(*n) = #{definer_body} }\n  my_sc_attr :a\nend\n"
      sib = "class Sib\n  singleton_class.class_eval { def my_sc_attr(*n) = n }\n  my_sc_attr :sib\nend\n"
      write_project(macro, %w[Sib.new.sib], extra_files: { "sib.rb" => sib })
      expect(undefined_messages).to eq(["undefined method `sib' for Sib"])
    end
  end

  describe "a singleton_class.class_eval inside a class << self body" do
    it "does not read its def as the class's macro, since it defines on the singleton's own singleton" do
      source = "class ScS\n  def self.my_x(*n) = n\n  class << self\n    singleton_class.class_eval { " \
               "def my_x(*n) = #{definer_body} }\n  end\n  my_x :y\nend\n"
      write_project(source, %w[ScS.new.y])
      expect(undefined_messages).to eq(["undefined method `y' for ScS"])
    end
  end

  describe "a mixin of Module.new whose body runs a computed define_method" do
    let(:macro) { "def self.my_inc(*n) = include(Module.new { #{definer_body} })" }

    it "opens the instance side of a class whose macro mixes it in" do
      write_project("class Inc\n  #{macro}\n  my_inc :ic\nend\n", %w[Inc.new.ic Inc.ic])
      expect(undefined_messages).to eq(["undefined method `ic' for singleton(Inc)"])
    end

    it "opens a class calling such a macro its superclass defines in another file" do
      write_project("class IncUse < IncBase\n  my_inc :id\nend\n", %w[IncUse.new.id],
                    extra_files: { "base.rb" => "class IncBase\n  #{macro}\nend\n" })
      expect(undefined_messages).to be_empty
    end

    it "opens the instance side of a class whose body mixes it in directly" do
      write_project("class IncBody\n  include(Module.new { %i[ib].each { |x| define_method(x) { x } } })\nend\n",
                    %w[IncBody.new.ib IncBody.zz])
      expect(undefined_messages).to eq(["undefined method `zz' for singleton(IncBody)"])
    end

    it "opens the instance side for a prepend of such a Module.new, in a macro or the class body" do
      source = "class Pre\n  def self.my_pre(*n) = prepend(Module.new { #{definer_body} })\n  my_pre :pr\nend\n" \
               "class PreBody\n  prepend(Module.new { %i[pb].each { |x| define_method(x) { x } } })\nend\n"
      write_project(source, %w[Pre.new.pr PreBody.new.pb])
      expect(undefined_messages).to be_empty
    end

    it "does not open a class for a Module.new that defines nothing" do
      write_project("class IncNone\n  include(Module.new { def self.x = 1 })\nend\n", %w[IncNone.new.zz])
      expect(undefined_messages).to eq(["undefined method `zz' for IncNone"])
    end
  end

  describe "the side of a macro's definer" do
    it "does not open a class whose instance-side macro defines, when the class-side one it calls does not" do
      source = "class Side\n  def my_attr(*n) = #{definer_body}\n  def self.my_attr(*n) = n\n  my_attr :q\nend\n"
      write_project(source, %w[Side.new.q])
      expect(undefined_messages).to eq(["undefined method `q' for Side"])
    end

    it "does not open a class whose instance-side macro, in another file, defines" do
      write_project("class Side2\n  def self.my_attr(*n) = n\n  my_attr :r\nend\n", %w[Side2.new.r],
                    extra_files: { "inst.rb" => "class Side2\n  def my_attr(*n) = #{definer_body}\nend\n" })
      expect(undefined_messages).to eq(["undefined method `r' for Side2"])
    end
  end
end
