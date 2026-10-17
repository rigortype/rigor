# frozen_string_literal: true

require "spec_helper"

# Issue #1936 — a singleton method a later non-`def` definer replaces (`singleton_class.alias_method`, its
# `define_method` / `remove_method` / `attr_*` / `class_eval`, `define_singleton_method`, or a `class << self` body's
# `attr_*` / `alias_method` / `alias`) must not be typed from the `def` Ruby replaced: the walk contests the `def`'s
# singleton slot and the typing read declines on the contest, so the call reads `Dynamic`. Each example's comment is
# Ruby 4.0.5's value of the call.
RSpec.describe "a singleton name a later definer rewrites is not typed from the replaced def (#1936)", type: :runner do
  def dumps(source)
    dumped = analyze(source).diagnostics.select { |d| d.qualified_rule == "dump.type" }
    dumped.map { |d| d.message.delete_prefix("dump_type: ") }
  end

  def rows(source, rule)
    analyze(source).diagnostics.select { |d| d.rule == rule }.map(&:line)
  end

  it "types the call Dynamic after each singleton_class rewrite of the name" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"] * 6)
      class T1; def self.x = "s"; def self.y = 1; singleton_class.alias_method :x, :y; end
      class T2; def self.x = "s"; singleton_class.define_method(:x) { 1 }; end
      class B4; def self.x = "s"; end
      class T4 < B4; def self.x = 1; singleton_class.remove_method :x; end
      class T5; def self.x = "s"; singleton_class.attr_reader :x; end
      class T6; def self.x = "s"; self.singleton_class.class_eval { def x = 1 }; end
      class T7; def self.x = "s"; define_singleton_method(:x) { 1 }; end
      Rigor.dump_type(T1.x) # 1
      Rigor.dump_type(T2.x) # 1
      Rigor.dump_type(T4.x) # "s"
      Rigor.dump_type(T5.x) # nil
      Rigor.dump_type(T6.x) # 1
      Rigor.dump_type(T7.x) # 1
    RUBY
  end

  it "types the call Dynamic after a class << self body rewrites the name" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"] * 4)
      class C1; def self.x = "s"; class << self; attr_reader :x; end; end
      class C2; def self.x = "s"; def self.y = 1; class << self; alias_method :x, :y; end; end
      class C3; def self.x = "s"; def self.y = 1; class << self; alias x y; end; end
      class C4; class << self; def x = "s"; define_method(:x) { 1 }; end; end
      Rigor.dump_type(C1.x) # nil
      Rigor.dump_type(C2.x) # 1
      Rigor.dump_type(C3.x) # 1
      Rigor.dump_type(C4.x) # 1
    RUBY
  end

  # Ruby: 1, and `1.even?` is true; the replaced def's "s" would report `even?` on a String.
  it "reports nothing downstream of the rewritten call" do
    expect(rows(<<~RUBY, "call.undefined-method")).to eq([])
      class T1; def self.x = "s"; def self.y = 1; singleton_class.alias_method :x, :y; end
      T1.x.even?
      class K; class << self; def x = 1; attr_reader :x; end; end
      K.instance_variable_set(:@x, "k")
      K.x.upcase
    RUBY
  end

  # A rewrite that may not run leaves the def a possible answer, never a certain one.
  it "types the call Dynamic after a rewrite behind a condition or in a block" do
    expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"] * 2)
      class P1; def self.x = "s"; def self.y = 1; singleton_class.alias_method :x, :y if ENV["Q"]; end
      class P2; def self.x = "s"; def self.y = 1; [1].each { singleton_class.alias_method :x, :y }; end
      Rigor.dump_type(P1.x) # "s" (Q unset)
      Rigor.dump_type(P2.x) # 1
    RUBY
  end

  it "keeps typing from a def that follows the rewrite, and from a def no rewrite names (controls)" do
    expect(dumps(<<~RUBY)).to eq(['"later"', '"s"', '"s"', '"s"'])
      class L; def self.y = 1; singleton_class.alias_method :x, :y; def self.x = "later"; end
      class N; def self.x = "s"; end
      class O; def self.x = "s"; def self.y = 1; singleton_class.alias_method :o2, :y; end
      class W; def self.x = "s"; singleton_class.attr_writer :x; end
      Rigor.dump_type(L.x) # "later"
      Rigor.dump_type(N.x) # "s"
      Rigor.dump_type(O.x) # "s"
      Rigor.dump_type(W.x) # "s"
    RUBY
  end

  # Ruby: ArgumentError — `attr_writer :x` defines `x=` alone, so `x` keeps its one-argument def.
  it "keeps checking the arity of a def an attr_writer of the name leaves in place" do
    expect(rows(<<~RUBY, "call.wrong-arity")).to eq([2])
      class F; def self.x(a) = a; singleton_class.attr_writer :x; end
      F.x(1, 2)
    RUBY
  end
end
