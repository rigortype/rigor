# frozen_string_literal: true

require "spec_helper"

# Issue #2983 — a `class_eval`-family block whose receiver is rooted at a constant other than the class's own spelling
# defines its `def` / `define_method` on that constant's module. When the constant names an ancestor of the class, an
# alias of it or one of its instances, the method runs on the class's instances and its `@x` write is theirs; the
# class-ivar census joins it in the same file and from another file alike. Each case is its own project, so one shape's
# write cannot reach another's reader. The reader is `K#get = @x.upcase` after `initialize` sets `@x = nil`: Ruby
# 4.0.5 returns "A" from `k.poke; k.set; k.get` in every quiet case and raises NoMethodError on nil in every
# reporting one.
RSpec.describe "ivar census: constant-rooted class_eval receivers (#2983)", type: :runner do
  def self.reader_body = "  def initialize = (@x = nil)\n  def get = @x.upcase\n"
  def self.definers = { "def" => 'def set = (@x = "a")', "define_method" => 'define_method(:set) { @x = "a" }' }

  def reader_body = self.class.reader_body
  def definers = self.class.definers

  def reported(files, sig: {})
    analyze(files: files, sig: sig).diagnostics.select { |d| d.rule.to_s == "call.undefined-method" }
                                   .map { |d| [File.basename(d.path), d.line] }.sort
  end

  # `setup` precedes the class, `header` follows `class K`, `after` follows the class (an alias or instance
  # constant), and `poke` is the receiver the block's `class_eval` is sent to. Single-file puts the poke in the
  # reader's file; cross-file puts it, with `after`, in a reopening in `b.rb`.
  def files_for(shape, definer, cross:)
    poke = "  def poke = #{shape.fetch(:poke)}.#{shape.fetch(:eval, 'class_eval')} { #{definers.fetch(definer)} }\n"
    head = "#{shape[:setup]}class K#{shape[:header]}\n#{reader_body}"
    after = shape[:after] ? "#{shape[:after]}\n" : ""
    return { "a.rb" => "#{head}end\n#{after}class K\n#{poke}end\n" } unless cross

    { "a.rb" => "#{head}end\n", "b.rb" => "#{after}class K\n#{poke}end\n" }
  end

  quiet = {
    "a superclass" => { setup: "class Anc; end\n", header: " < Anc", poke: "Anc" },
    "an included module" => { setup: "module M; end\n", header: "\n  include M", poke: "M", eval: "module_eval" },
    "an instance constant's class" => { after: "INST = K.new", poke: "INST.class" },
    "an instance constant's singleton class" => { after: "INST = K.new", poke: "INST.singleton_class" },
    "an alias's new instance's class" => { after: "AliasK = K", poke: "AliasK.new.class" },
    "Object" => { poke: "Object" },
    "BasicObject" => { poke: "BasicObject" },
    "Kernel" => { poke: "Kernel", eval: "module_eval" },
    # Guards: a container literal or a block may hold the class's instance (`[self].first`), and a String spelling a
    # constant may be resolved to the class (`String#constantize` below, as ActiveSupport's).
    "a container literal's element" => { poke: "[self].first.class" },
    "a literal's block call" => { poke: '"s".then { self }.class' },
    "a constant-spelling String" => {
      after: "class String\n  def constantize = Object.const_get(self)\nend", poke: '"K".constantize'
    }
  }.freeze

  reporting = {
    "an unrelated class" => { setup: "class Other; end\n", poke: "Other" },
    "an unrelated instance constant's class" => { setup: "class Other; end\nOTHER = Other.new\n", poke: "OTHER.class" },
    "an unrelated alias" => { setup: "class Other; end\nAliasOther = Other\n", poke: "AliasOther.new.class" }
  }.freeze

  [false, true].each do |cross|
    layout = cross ? "cross-file" : "single-file"
    definers.each_key do |definer|
      quiet.each do |label, shape|
        it "credits #{label}'s #{definer} write to the class (#{layout})" do
          expect(reported(files_for(shape, definer, cross: cross))).to eq([])
        end
      end

      reporting.each do |label, shape|
        it "keeps reporting for #{label}'s #{definer} write (#{layout})" do
          line = shape.fetch(:setup).lines.size + 3
          expect(reported(files_for(shape, definer, cross: cross))).to eq([["a.rb", line]])
        end
      end
    end
  end

  # Item 2: a chain rooted at a scalar literal names a core class whatever blockless calls it goes through, so the
  # write is `String`'s and `@x` stays nil: Ruby 4.0.5 returns "none" from `k.poke; "s".set; k.label`.
  definers.each_key do |definer|
    [false, true].each do |cross|
      it "reads a literal-rooted chain through a non-preserving call as foreign (#{definer}, " \
         "#{cross ? 'cross-file' : 'single-file'})" do
        body = definers.fetch(definer).sub('"a"', "1")
        poke = "class K\n  def poke = \"s\".upcase.class.class_eval { #{body} }\nend\n"
        source = "class K\n  def initialize = (@x = nil)\n  def label = (@x.nil? ? \"none\" : @x.upcase)\nend\n"
        files = cross ? { "a.rb" => source, "b.rb" => poke } : { "a.rb" => source + poke }
        expect(reported(files)).to eq([])
      end
    end
  end

  # Item 3: an `Object.class_eval` in another class's body, or at the top level, defines a method every object runs.
  %w[Object BasicObject Kernel].each do |root|
    eval_call = root == "Kernel" ? "module_eval" : "class_eval"
    {
      "another class's body" => "class Host\n  def poke = #{root}.#{eval_call} { def set = (@x = \"a\") }\nend\n",
      "the top level" => "#{root}.#{eval_call} { def set = (@x = \"a\") }\n"
    }.each do |where, writer|
      it "credits #{root}.#{eval_call} in #{where} of another file" do
        expect(reported({ "a.rb" => "class K\n#{reader_body}end\n", "b.rb" => writer })).to eq([])
      end
    end
  end

  # Item 4: a String `class_eval` whose receiver may be the class runs code the census cannot read, so every ivar of
  # the class widens; one on an unrelated constant widens that constant's ivars only.
  {
    "self.class" => [],
    "K" => [],
    "Other" => [["a.rb", 4]]
  }.each do |receiver, expected|
    ["def set = (@x = 'a')", "define_method(:set) { @x = 'a' }"].each do |code|
      [false, true].each do |cross|
        it "reads #{receiver}.class_eval(#{code.inspect}) (#{cross ? 'cross-file' : 'single-file'})" do
          poke = "class K\n  def poke = #{receiver}.class_eval(#{code.inspect})\nend\n"
          source = "class Other; end\nclass K\n#{reader_body}end\n"
          files = cross ? { "a.rb" => source, "b.rb" => poke } : { "a.rb" => source + poke }
          expect(reported(files)).to eq(expected)
        end
      end
    end
  end

  # A String `class_eval` on the implicit receiver in the class body evals in the class itself.
  [false, true].each do |cross|
    it "reads a class-body class_eval(String) (#{cross ? 'cross-file' : 'single-file'})" do
      poke = "class K\n  class_eval(\"def set = (@x = 'a')\")\nend\n"
      source = "class K\n#{reader_body}end\n"
      files = cross ? { "a.rb" => source, "b.rb" => poke } : { "a.rb" => source + poke }
      expect(reported(files)).to eq([])
    end
  end
  # Review round 1: a credit reaches only the class the receiver resolves to. `Object` and `Kernel` are no ancestors
  # of a `BasicObject` subclass, a binding names the class its own lexical scope resolves, and a root constant
  # resolves through the poke's lexical nesting, nearest first, as Ruby's constant lookup does. In each quiet case
  # with a `label` reader, Ruby 4.0.5 returns "none" after every poke and `set` the code allows; in each `get` case it
  # returns "A"; and the `Plain` reader raises NoMethodError on 1.
  narrowing = "    def initialize = (@x = nil)\n    def label = (@x ? @x.upcase : \"none\")\n"
  plain = "    def initialize = (@x = nil)\n    def get = @x.upcase\n"
  {
    "a BasicObject subclass ignores Object.class_eval" =>
      ["class BO < BasicObject\n#{narrowing}end\n", "class Host\n  def poke = Object.class_eval { %s }\nend\n", 1, []],
    "a BasicObject subclass ignores Kernel.module_eval" =>
      ["class BO < BasicObject\n#{narrowing}end\n", "class Host\n  def poke = Kernel.module_eval { %s }\nend\n", 1, []],
    "an Object subclass takes Object.class_eval" =>
      ["class Plain\n#{narrowing}end\n", "class Host\n  def poke = Object.class_eval { %s }\nend\n", 1,
       [["a.rb", 3]]],
    "a same-named class in another namespace ignores an instance constant's binding" =>
      ["module Ns2\n  class K\n#{narrowing}  end\nend\n",
       "module Ns1\n  class K\n    def poke = INST.class.class_eval { %s }\n  end\nend\nINST = Ns1::K.new\n", 1, []],
    "the bound namespaced class takes an instance constant's binding" =>
      ["module Ns1\n  class K\n#{plain}  end\nend\n",
       "module Ns1\n  class K\n    def poke = INST.class.class_eval { %s }\n  end\nend\nINST = Ns1::K.new\n",
       '"a"', []],
    "a namespaced binding written in the namespace binds the class it resolves to" =>
      ["module Ns1\n  class K\n#{plain}  end\nend\n",
       "module Ns1\n  INST = K.new\n  class K\n    def poke = INST.class.class_eval { %s }\n  end\nend\n", '"a"', []],
    "a top-level constant of the same name ignores a namespaced binding" =>
      ["class Plain\n#{narrowing}end\nINST = Plain.new\n",
       "module Ns1\n  INST = K.new\n  class K\n    def poke = INST.class.class_eval { %s }\n  end\nend\n", 1, []],
    "a BasicObject subclass takes BasicObject.class_eval" =>
      ["class BO < BasicObject\n#{plain}end\n",
       "class Host\n  def poke = BasicObject.class_eval { %s }\nend\n", '"a"', []],
    "a top-level class whose superclass shares the root's last name ignores it" =>
      ["class Anc; end\nclass TopK < ::Anc\n#{narrowing}end\n",
       "module N\n  class Anc; end\n  class K < Anc\n    def poke = Anc.class_eval { %s }\n  end\nend\n", 1, []],
    "a namespaced class takes the root its nesting resolves" =>
      ["module N\n  class Anc; end\n  class K < Anc\n#{plain}  end\nend\n",
       "module N\n  class K\n    def poke = Anc.class_eval { %s }\n  end\nend\n", '"a"', []],
    # Review round 2: a nearer candidate only a signature declares is the constant Ruby finds, so the top-level
    # project `Anc` takes nothing; without the signature it is `Anc` and its subclass raises on 1.
    "a nearer candidate only a signature declares shadows a top-level project class" =>
      ["class Anc; end\nclass TopK < Anc\n#{narrowing}end\n",
       "module N\n  class K\n    def poke = Anc.class_eval { %s }\n  end\nend\n", 1, [],
       { "n.rbs" => "module N\n  class Anc\n  end\nend\n" }],
    "the top-level project class takes the write when no signature declares a nearer one" =>
      ["class Anc; end\nclass TopK < Anc\n#{narrowing}end\n",
       "module N\n  class K\n    def poke = Anc.class_eval { %s }\n  end\nend\n", 1, [["a.rb", 4]]],
    # Review round 2: the singleton class of a class object, `Class`, and a class object's metaclass hold methods no
    # instance runs, so the class's own `@x` stays nil.
    "a class constant's singleton class credits no instance" =>
      ["class Other\n#{narrowing}end\n", "class K\n  def poke = Other.singleton_class.class_eval { %s }\nend\n", 1, []],
    "a class constant's class credits no instance" =>
      ["class Other\n#{narrowing}end\n", "class K\n  def poke = Other.class.class_eval { %s }\nend\n", 1, []],
    "a new instance's class's singleton class credits no instance" =>
      ["class Other\n#{narrowing}end\n",
       "class K\n  def poke = Other.new.class.singleton_class.class_eval { %s }\nend\n", 1, []],
    "a rooted instance constant's class takes the write" =>
      ["class K\n#{plain}end\nINST = K.new\n", "class K\n  def poke = ::INST.class.class_eval { %s }\nend\n", '"a"',
       []],
    "a copied class constant's singleton class credits no instance" =>
      ["class Other\n#{narrowing}end\n", "class K\n  def poke = Other.dup.singleton_class.class_eval { %s }\nend\n", 1,
       []]
  }.each do |label, (reader, writer, value, expected, sig)|
    definers.each do |definer, code|
      [false, true].each do |cross|
        it "#{label} (#{definer}, #{cross ? 'cross-file' : 'single-file'})" do
          poke = format(writer, code.sub('"a"', value.to_s))
          files = cross ? { "a.rb" => reader, "b.rb" => poke } : { "a.rb" => reader + poke }
          expect(reported(files, sig: sig || {})).to eq(expected)
        end
      end
    end
  end
end
