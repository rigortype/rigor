# frozen_string_literal: true

require "spec_helper"

# Issue #2284 — a project singleton definer of a name `Module` / `Class` also declares (`def self.name`) answers a
# call on the class object, not the `Singleton[Object]` fallback's `Module#name -> String`: Ruby's singleton
# ancestry puts every project entry ahead of `Class`. Each example's comment is Ruby 4.0.5's value of the call.
RSpec.describe "a project singleton override of a Module method wins on the class object (#2284)", type: :runner do
  def dumps(source = nil, files: {})
    result = files.empty? ? analyze(source) : analyze(files: files)
    dumped = result.diagnostics.select { |d| d.qualified_rule == "dump.type" }
    dumped.map { |d| d.message.delete_prefix("dump_type: ") }
  end

  def undefined_methods(source)
    analyze(source).diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  it "types the call from the class's own def self.name and reports nothing on the result" do
    expect(dumps(<<~RUBY)).to eq(%w[42 42 42])
      class Base2; def self.name = 42; end
      Rigor.dump_type(Base2.name) # 42
      Rigor.dump_type(Base2.new.class.name) # 42
      class Sub < Base2; end
      Rigor.dump_type(Sub.name) # 42, inherited
    RUBY
    expect(undefined_methods(<<~RUBY)).to eq([])
      class Base2; def self.name = 42; end
      Base2.name.even?
    RUBY
  end

  it "types the call from a class << self body, a module's def self.name and an extended module" do
    expect(dumps(<<~RUBY)).to eq(%w[43 44 45])
      class Cs; class << self; def name = 43; end; end
      module M1; def self.name = 44; end
      module N; def name = 45; end
      class Ce; extend N; end
      Rigor.dump_type(Cs.name) # 43
      Rigor.dump_type(M1.name) # 44
      Rigor.dump_type(Ce.name) # 45
    RUBY
  end

  it "keeps String where only the instance side defines the name, and where nothing does (controls)" do
    expect(dumps(<<~RUBY)).to eq(%w[String String])
      class Foo; def name = 1; end
      class Bar; end
      Rigor.dump_type(Foo.name) # "Foo"
      Rigor.dump_type(Bar.name.upcase) # "BAR"
    RUBY
  end

  # The instance side reaches `Kernel#inspect` / `#to_s`, never the class's singleton `def`.
  it "keeps String for an instance receiver of a class with singleton inspect / to_s defs" do
    expect(dumps(<<~RUBY)).to eq(%w[String String])
      class Gi; def self.inspect = 1; def self.to_s = 2; end
      Rigor.dump_type(Gi.new.inspect) # "#<Gi>"
      Rigor.dump_type(Gi.new.to_s) # "#<Gi>"
    RUBY
  end

  # A nearer class defining the name without a `def` is the method Ruby calls, so the farther `def` must not answer.
  it "types the call Dynamic when a nearer class defines the name without a def" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"] * 6)
      class B1; def self.name = nil; def self.to_s = nil; def self.foo = nil; end
      class S1 < B1; define_singleton_method(:name) { "s" }; end
      class S2 < B1; singleton_class.define_method(:name) { "s" }; end
      class S3 < B1; singleton_class.attr_reader :name; end
      class S4 < B1; define_singleton_method(:to_s) { "s" }; end
      class S5 < B1; define_singleton_method(:foo) { "s" }; end
      class S6 < B1; NAMES = %i[name].freeze; NAMES.each { |n| define_singleton_method(n) { "s" } }; end
      Rigor.dump_type(S1.name) # "s"
      Rigor.dump_type(S2.name) # "s"
      Rigor.dump_type(S3.name) # nil
      Rigor.dump_type(S4.to_s) # "s"
      Rigor.dump_type(S5.foo) # "s"
      Rigor.dump_type(S6.name) # "s", computed name
    RUBY
    expect(undefined_methods(<<~RUBY)).to eq([])
      class B1; def self.name = nil; end
      class S1 < B1; define_singleton_method(:name) { "s" }; end
      S1.name.upcase
    RUBY
  end

  # An `extend`ed module's `attr_*` or `define_method`, or its `extended` hook, defines the name Ruby calls ahead of
  # the superclass's `def`.
  it "types the call Dynamic when a nearer extended module defines the name without a def" do
    expect(dumps(<<~RUBY)).to eq((["Dynamic[top]"] * 4) + ["nil"])
      class Bo; def self.name = nil; end
      module Em; attr_reader :name; end
      class E1 < Bo; extend Em; @name = "x"; end
      module Ea; attr_accessor :name; end
      class E2 < Bo; extend Ea; self.name = "x"; end
      module Fw; def self.extended(b) = b.define_singleton_method(:name) { "x" }; end
      class E3 < Bo; extend Fw; end
      module Dm; define_method(:name) { "d" }; end
      class E4 < Bo; extend Dm; end
      module Plain; def other = 1; end
      class E5 < Bo; extend Plain; end
      Rigor.dump_type(E1.name) # "x"
      Rigor.dump_type(E2.name) # "x"
      Rigor.dump_type(E3.name) # "x"
      Rigor.dump_type(E4.name) # "d"
      Rigor.dump_type(E5.name) # nil
    RUBY
    expect(undefined_methods(<<~RUBY)).to eq([])
      class Bo; def self.name = nil; end
      module Em; attr_reader :name; end
      class E1 < Bo; extend Em; @name = "x"; end
      E1.name.upcase
    RUBY
  end

  # An `inherited` hook on an ancestor runs when the subclass is created and may define the name on it.
  it "reports nothing on a subclass whose ancestor's inherited hook may redefine the name" do
    expect(undefined_methods(<<~RUBY)).to eq([])
      class Top1; def self.name = nil; def self.inherited(s) = s.define_singleton_method(:name) { "x" }; end
      class Sh1 < Top1; end
      class Top2; def self.name = nil; def self.inherited(s) = (s.singleton_class.attr_accessor :name; s.name = "y"); end
      class Sh2 < Top2; end
      class Top3; def self.name = nil; def self.inherited(s); super; s.class_eval { def self.name = "z" }; end; end
      class Sh3 < Top3; end
      module Hk; def inherited(s) = s.define_singleton_method(:name) { "m" }; end
      class Top4; extend Hk; def self.name = nil; end
      class Sh4 < Top4; end
      module Hd; define_method(:inherited) { |s| s.define_singleton_method(:name) { "d" } }; end
      class Top5; extend Hd; def self.name = nil; end
      class Sh5 < Top5; end
      Sh1.name.upcase # "X"
      Sh2.name.upcase # "Y"
      Sh3.name.upcase # "Z"
      Sh4.name.upcase # "M"
      Sh5.name.upcase # "D"
    RUBY
  end

  it "keeps the inherited def's type in a hierarchy with no inherited hook (control)" do
    expect(dumps(<<~RUBY)).to eq(%w[7 nil 7 8])
      class Top5; def self.name = 7; end
      class Sh5 < Top5; end
      class Top6; def self.name = nil; def self.inherited(s) = s.define_singleton_method(:name) { "x" }; end
      class Sh7 < Top5; def self.inherited(s) = super; end
      class Own < Top6; def self.name = 8; end
      Rigor.dump_type(Sh5.name) # 7
      Rigor.dump_type(Top6.name) # nil, the hook's own class is not created by it
      Rigor.dump_type(Sh7.name) # 7, its own hook runs for its subclasses only
      Rigor.dump_type(Own.name) # 8, its own def replaces what the hook defined
    RUBY
  end

  # A contest farther than the `def`'s owner does not reach the call: the nearer `def` runs.
  it "keeps a nearer def's type when a farther class defines the name without a def" do
    expect(dumps(<<~RUBY)).to eq(["5"])
      class Top; end
      class Far < Top; define_singleton_method(:name) { "f" }; end
      class NearDef < Far; def self.name = 5; end
      Rigor.dump_type(NearDef.name) # 5
    RUBY
  end

  # The def may not run, so neither its type nor String alone is the answer.
  it "does not answer String alone for a def behind a condition" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
      class Cond; def self.name = 46 if ENV["Q"]; end
      Rigor.dump_type(Cond.name) # "Cond" (Q unset)
    RUBY
  end

  it "resolves an override written in another file, and keeps a sibling's same-named override to its class" do
    expect(dumps(files: {
                   "base.rb" => "class Base3; def self.name = 42; end\n",
                   "other.rb" => "class Other3; def self.name = :other; end\n",
                   "sub.rb" => "class Sub3 < Base3; end\n",
                   "dyn.rb" => "class Dyn3 < Base3; define_singleton_method(:name) { \"d\" }; end\n",
                   "use.rb" => <<~RUBY
                     class Plain3; end
                     Rigor.dump_type(Base3.name) # 42
                     Rigor.dump_type(Sub3.name) # 42
                     Rigor.dump_type(Plain3.name) # "Plain3"
                     Rigor.dump_type(Dyn3.name) # "d"
                   RUBY
                 })).to eq(["42", "42", "String", "Dynamic[top]"])
  end
end
