# frozen_string_literal: true

require "spec_helper"

# Issue #1885. A memoizing index `||=` whose `[]` read is a lone `Dynamic` reads as its rvalue (the memoization
# exception, `StatementEvaluator#index_compound_write_value`). A store earlier in the same straight-line body may
# already have filled the slot, and when that store is conditional, or sits in a block, its slot narrowing does not
# reach the later site, so the site read as empty: `c0[:k] ||= :e if cond; l0 = (c0[:k] ||= :f).itself` typed `l0`
# as `:f` and reported `l0 == :e` always falsey, where Ruby with `cond` true prints `e`. Every fixture below prints
# `e` under Ruby for the input that makes its condition hold.
RSpec.describe "a memoizing index `||=` after an earlier store on a straight-line path", type: :runner do
  def analyzed(source) = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))

  def flow_rules(source)
    analyzed(source).diagnostics.filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.")
    end
  end

  def dumped_type(source)
    dumps = analyzed(source).diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
    expect(dumps.size).to eq(1)
    dumps.first
  end

  it "does not fold the reported probe (a modifier `if` store)" do
    expect(flow_rules(<<~RUBY)).to be_empty
      cond = gets.to_s.empty?
      c0 = Hash.new
      c0[:k] ||= :e if cond
      l0 = (c0[:k] ||= :f).itself
      puts "e" if l0 == :e
    RUBY
  end

  it "does not read the slot as empty after an `if`, an `unless`, a ternary or a `&&` store" do
    expect(dumped_type(<<~RUBY)).to eq("[Dynamic[top], Dynamic[top], Dynamic[top], Dynamic[top]]")
      cond = gets.to_s.empty?
      c1 = Hash.new
      if cond then c1[:k] ||= :e end
      c2 = Hash.new
      unless cond then c2[:k] ||= :e end
      c3 = Hash.new
      cond ? (c3[:k] ||= :e) : nil
      c4 = Hash.new
      cond && (c4[:k] ||= :e)
      dump_type([(c1[:k] ||= :f).itself, (c2[:k] ||= :f).itself, (c3[:k] ||= :f).itself, (c4[:k] ||= :f).itself])
    RUBY
  end

  it "does not read it as empty after a store in a block its call runs once" do
    expect(flow_rules(<<~RUBY)).to be_empty
      cond = gets.to_s.empty?
      c1 = Hash.new
      1.tap { c1[:k] ||= :e if cond }
      l1 = (c1[:k] ||= :f).itself
      c2 = Hash.new
      1.then { c2[:k] ||= :e if cond }
      l2 = (c2[:k] ||= :f).itself
      puts "e" if l1 == :e
      puts "e" if l2 == :e
    RUBY
  end

  it "does not read it as empty after a plain `[]=` store" do
    expect(flow_rules(<<~RUBY)).to be_empty
      cond = gets.to_s.empty?
      c0 = Hash.new
      c0[:k] = :e if cond
      l0 = (c0[:k] ||= :f).itself
      puts "e" if l0 == :e
    RUBY
  end

  it "marks the site in a method body, on an instance-variable receiver" do
    expect(flow_rules(<<~RUBY)).to be_empty
      class Memo
        def initialize = @h = Hash.new

        def run(cond)
          @h[:k] ||= :e if cond
          l = (@h[:k] ||= :f).itself
          puts "e" if l == :e
        end
      end
    RUBY
  end

  it "does not read an array slot as empty either (guard)" do
    # A guard, not a pin of the marks: the array literal's widened element read is no lone `Dynamic`, so the
    # memoization reading never applied here, with or without them.
    expect(flow_rules(<<~RUBY)).to be_empty
      def run(cond)
        a = []
        a[0] ||= :e if cond
        l = (a[0] ||= :f).itself
        puts "e" if l == :e
      end
    RUBY
  end

  it "marks it past a `return if` between the two sites" do
    expect(flow_rules(<<~RUBY)).to be_empty
      def run(cond)
        c = Hash.new
        c[:k] ||= :e if cond
        return if cond.nil?

        l = (c[:k] ||= :f).itself
        puts "e" if l == :e
      end
    RUBY
  end

  it "marks it after a store in a `begin` body a `rescue` follows" do
    expect(flow_rules(<<~RUBY)).to be_empty
      def run(cond)
        c = Hash.new
        begin
          c[:k] ||= :e
          raise "x" if cond
        rescue StandardError
          nil
        end
        l = (c[:k] ||= :f).itself
        puts "e" if l == :e
      end
    RUBY
  end

  it "marks it in the return the call site infers for a method" do
    # The user-method return re-walk types the body from a scope of its own, and lays the marks there too.
    expect(flow_rules(<<~RUBY)).to be_empty
      class Lookup
        def run(cond)
          c = Hash.new
          c[:k] ||= :e if cond
          (c[:k] ||= :f).itself
        end
      end
      puts "e" if Lookup.new.run(gets) == :e
    RUBY
  end

  it "does not read it as empty when a `for` loop runs both arms of a ternary in turn" do
    # Ruby with input `,a` prints `e`: the first element stores `:e` and the second keeps it.
    expect(flow_rules(<<~RUBY)).to be_empty
      c = Hash.new
      l = nil
      for x in gets.to_s.split(",", -1)
        x.empty? ? (c[:k] ||= :e) : (l = (c[:k] ||= :f).itself)
      end
      puts "e" if l == :e
    RUBY
  end

  it "keeps the rvalue reading for a different literal key (control)" do
    expect(dumped_type(<<~RUBY)).to eq("2")
      c = Hash.new
      c[:a] ||= 1 if gets
      dump_type((c[:b] ||= 2).itself)
    RUBY
  end

  it "keeps it for a store in the other arm of an `if` (control)" do
    # The arms are exclusive, so the `:e` store never runs before the `:f` site.
    expect(dumped_type(<<~RUBY)).to eq(":f?")
      c = Hash.new
      l = nil
      if gets then c[:k] ||= :e else l = (c[:k] ||= :f).itself end
      dump_type(l)
    RUBY
  end
end
