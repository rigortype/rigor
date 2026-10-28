# frozen_string_literal: true

require "spec_helper"

# Issue #2499 — the accumulator idiom. A heap slot seeded with an empty literal is filled later from code the census
# cannot see (a subclass, a mixin, another file, a memoised accessor, an `attr_reader` caller), so the seed is never
# proof of emptiness (rule 1). A non-empty literal keeps its exact type (rule 2). A stdlib call that fills a String
# argument widens it (rule 3). Each source carries Ruby 4.0.5's behaviour: every guarded line runs its `puts`.
RSpec.describe "accumulator seeds (#2499)", type: :runner do
  def folds(files)
    analyze(files: files).diagnostics.select { |d| d.rule.to_s == "flow.always-truthy-condition" }
                         .map { |d| [File.basename(d.path), d.line] }.sort
  end

  # A local in straight-line code keeps its precision, so every fixture can also prove it was analysed.
  def control_source = "def control\n  c = +\"\"\n  puts 1 if c.length > 0\nend\n"

  def expect_only_control(source, name = "code.rb", extra = {})
    files = { name => "#{source}#{control_source}" }.merge(extra)
    control_line = files[name].lines.index { |l| l.include?("c.length > 0") } + 1
    expect(folds(files)).to eq([[name, control_line]])
  end

  describe "rule 1: an empty seed is never proof of emptiness" do
    it "does not fold an ivar a subclass appends to (#2491)" do
      expect_only_control(<<~RUBY)
        class Base; def initialize = @s = ""; def go = (puts 1 if @s.length > 0); end
        class Sub < Base; def add(x) = @s << x; end
      RUBY
    end

    it "does not fold an Array ivar a subclass appends to (#2491)" do
      expect_only_control(<<~RUBY)
        class BaseA; def initialize = @s = []; def go = (puts 1 if @s.size > 0); end
        class SubA < BaseA; def add(x) = @s << x; end
      RUBY
    end

    it "does not fold an ivar a mixin appends to (#2491)" do
      expect_only_control(<<~RUBY)
        module Appender; def add(x) = @out << x; end
        class Host; include Appender; def initialize = @out = ""; def go = (puts 1 if @out.length > 0); end
      RUBY
    end

    it "does not fold an ivar another file appends to (#2491)" do
      expect_only_control(<<~RUBY, "a.rb", "b.rb" => "class Gv; def add(x) = @s << x; end\n")
        class Gv; def initialize = @s = ""; def go = (puts 1 if @s.length > 0); end
      RUBY
    end

    it "does not fold a memoised `@buf ||= +\"\"` (#2492)" do
      expect_only_control(<<~RUBY)
        class Memo
          def buf = @buf ||= +""
          def add(x) = buf << x
          def flush; return unless @buf; puts 1 if @buf.length > 0; end
        end
      RUBY
    end

    it "does not fold a memoised `@buf ||= []` (#2492)" do
      expect_only_control(<<~RUBY)
        class MemoA
          def buf = @buf ||= []
          def add(x) = buf << x
          def flush; return unless @buf; puts 1 if @buf.size > 0; end
        end
      RUBY
    end

    it "does not fold an ivar an attr_reader caller appends to (#2492)" do
      expect_only_control(<<~RUBY)
        class AR
          attr_reader :s
          def initialize = @s = ""
          def go = (puts 1 if @s.length > 0)
        end
        o = AR.new; o.s << "x"
      RUBY
    end

    it "does not fold a class variable another file appends to" do
      expect_only_control(<<~RUBY, "a.rb", "b.rb" => "class CV; def add(x) = @@buf << x; end\n")
        class CV
          def self.reset = @@buf = ""
          def go = (puts 1 if @@buf.length > 0)
        end
      RUBY
    end

    it "does not fold a String or Array global a method appends to (#2496)" do
      expect_only_control(<<~RUBY)
        $g = ""
        def g01 = $g << "x"
        def g02 = (puts 1 if $g.length > 0)
        $list = []; def r5 = $list << 1; def r6 = (puts 1 if $list.size > 0)
      RUBY
    end

    it "does not fold a global another file appends to (#2496)" do
      expect_only_control(<<~RUBY, "a.rb", "b.rb" => "$out << \"x\"\n")
        $out = ""
        def rd = (puts 1 if $out.length > 0)
      RUBY
    end

    it "does not fold a constant another file appends to (#2497)" do
      expect_only_control(<<~RUBY, "a.rb", "b.rb" => "Cfg::PREFIX << \"pre\"\n")
        module Cfg; PREFIX = ""; def self.go = (puts 1 if PREFIX.length > 0); end
      RUBY
    end

    it "does not fold a constant mutated through a method's return (#2497)" do
      expect_only_control(<<~RUBY)
        DEFAULT = ""; def ret_const = DEFAULT
        x = ret_const; x << "y"; puts 1 if ret_const.length > 0
      RUBY
    end

    it "does not fold an empty Hash ivar another method stores into through an alias" do
      expect_only_control(<<~RUBY)
        class HostH
          def initialize = @h = {}
          def table = @h
          def go = (puts 1 if @h.size > 0)
        end
        HostH.new.table[:k] = 1
      RUBY
    end
  end

  describe "rule 2: a non-empty literal keeps its exact type (guards)" do
    it "still folds a String ivar against another literal (guard)" do
      expect(folds("code.rb" => <<~RUBY)).to eq([["code.rb", 3]])
        class Order
          def initialize = @order = "asc"
          def go = (puts 1 if @order == "desc")
        end
      RUBY
    end

    it "still folds a %w constant's size (guard)" do
      expect(folds("code.rb" => "MODES = %w[a b]\ndef go = (puts 1 if MODES.size > 2)\n")).to eq([["code.rb", 2]])
    end

    it "still folds a Hash ivar's known value (guard)" do
      expect(folds("code.rb" => <<~RUBY)).to eq([["code.rb", 3]])
        class Opts
          def initialize = @opts = { a: 1 }
          def go = (puts 1 if @opts[:a] == 2)
        end
      RUBY
    end

    it "passes a literal ivar to a literal-typed RBS parameter without a mismatch (guard)" do
      sig = { "sorter.rbs" => "class Sorter\n  def sort: (\"asc\" | \"desc\") -> void\nend\n" }
      source = <<~RUBY
        class Sorter
          def sort(order) = order
        end
        class User
          def initialize
            @sorter = Sorter.new
            @order = "asc"
            @free = String.new
          end
          def go = @sorter.sort(@order)
          def bad = @sorter.sort(@free)
        end
      RUBY
      diagnostics = analyze(files: { "code.rb" => source }, sig: sig).diagnostics
      mismatches = diagnostics.select { |d| d.rule.to_s == "call.argument-type-mismatch" }.map(&:line)
      expect(mismatches).to eq([11])
    end
  end

  describe "rule 3: a stdlib out-buffer argument loses its exact type" do
    it "widens a local `io.read(n, buf)` fills" do
      expect_only_control("def r1(io)\n  buf = +\"\"\n  io.read(10, buf)\n  puts 1 if buf.length > 0\nend\n")
    end

    it "widens a local `readpartial`, `sysread` and `read_nonblock` fill" do
      expect_only_control(<<~RUBY)
        def r2(io)
          a = +""
          io.readpartial(4, a)
          puts 1 if a.length > 0
          b = +""
          io.sysread(3, b)
          puts 1 if b.length > 0
          c2 = +""
          io.read_nonblock(5, c2, exception: false)
          puts 1 if c2.length > 0
        end
      RUBY
    end

    it "widens the String a StringIO wraps" do
      expect_only_control("def r3\n  s = +\"\"\n  io = StringIO.new(s)\n  io.write(\"x\")\n  " \
                          "puts 1 if s.length > 0\nend\n")
    end

    it "widens the String a rooted ::StringIO wraps" do
      expect_only_control("def r4\n  s = +\"\"\n  io = ::StringIO.new(s)\n  io << \"x\"\n  " \
                          "puts 1 if s.length > 0\nend\n")
    end

    it "widens an ivar buffer in the method that seeds it" do
      expect_only_control(<<~RUBY)
        class R4
          def go(io)
            @b = +""
            io.read(4, @b)
            puts 1 if @b.length > 0
          end
        end
      RUBY
    end
  end
end
