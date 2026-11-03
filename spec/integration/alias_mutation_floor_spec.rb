# frozen_string_literal: true

require "spec_helper"

# Issue #2335 — a local's literal shape describes its object. A mutation through another path to that object (a copy,
# a block parameter, a container slot, an ivar, a call result, an argument a callee keeps) left the local's literal
# behind, and a later read reported on correct code. Every body below runs clean in Ruby.
RSpec.describe "a mutation through another holder floors the locals it may reach (#2335)", type: :runner do
  def prelude
    %(require "rigor/testing"\ninclude Rigor::Testing\n)
  end

  def undefined_methods(source)
    analyze(source).diagnostics.map(&:qualified_rule).grep(/undefined-method/)
  end

  def dumped(source)
    analyze("#{prelude}#{source}").diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  it "reports a read of the literal itself (the control that the rule is live)" do
    expect(undefined_methods("def m; a = [1]; a.last.bytesize; end\n")).to eq(["call.undefined-method"])
  end

  {
    "a copy" => 'x = [1]; y = x; y << "s"; x.last.bytesize',
    "the copied-from local" => 'x = [1]; y = x; x << "s"; y.last.bytesize',
    "a literal-symbol send" => 'a = [1]; a.send(:push, "s"); a.last.bytesize',
    "a block parameter of an Array holding it" => 'inner = [1]; a = [inner]; a.each { |x| x << "s" }; ' \
                                                  "inner.last.bytesize",
    "an element read into a local in a loop" => 'a = [[1]]; i = 0; while i < 1; x = a[i]; x << "s"; i += 1; end; ' \
                                                "a[0].last.bytesize",
    "a copy of an Array.new carrier" => 'a = Array.new(2, 0); b = a; b << "s"; a.last.bytesize',
    "a tap block parameter" => 'a = [1]; a.tap { |x| x << "s" }; a.last.bytesize',
    "a block parameter of a literal holding it" => 'a = [1]; [a].each { |y| y << "s" }; a.last.bytesize',
    "a numbered block parameter" => 'a = [1]; [a].each { _1 << "s" }; a.last.bytesize',
    "an it block parameter" => 'a = [1]; [a].each { it << "s" }; a.last.bytesize',
    "a Hash slot" => 'a = [1]; h = {}; h[:k] = a; h[:k] << "s"; a.last.bytesize',
    "an ivar" => 'a = [1]; @a = a; @a << "s"; a.last.bytesize',
    "a Hash default" => 'a = [1]; Hash.new(a)[:k] << "s"; a.last.bytesize',
    "an Array.new fill" => 'a = [1]; Array.new(1, a)[0] << "s"; a.last.bytesize',
    "a Struct member" => 'a = [1]; Struct.new(:v).new(a).v << "s"; a.last.bytesize',
    "an index write through a copy" => 'acc = [7]; r = acc; r[0] = "x"; acc[0].upcase',
    "a copy made on an earlier pass of a loop" => 'a = [1]; x = nil; i = 0; while i < 2; x << "s" if x; x = a; ' \
                                                  "i += 1; end; a.last.bytesize",
    "a proc that runs after the local is handed on" => 'a = [1]; pr = proc { |y| y << "s" }; @k = a; pr.call(a); ' \
                                                       "a.last.bytesize"
  }.each do |path, body|
    it "stays silent after a mutation through #{path}" do
      expect(undefined_methods("def m; #{body}; end\n")).to eq([])
    end
  end

  it "stays silent after an attribute the object was stored in is mutated" do
    source = <<~RUBY
      class H; attr_accessor :items; end
      def m; a = [1]; h = H.new; h.items = a; h.items << "s"; a.last.bytesize; end
    RUBY
    expect(undefined_methods(source)).to eq([])
  end

  it "stays silent after a method mutates the ivar a constructor kept the object in" do
    source = <<~RUBY
      class Box
        def initialize(a); @items = a; end
        def add(v); @items << v; end
      end
      def m; a = [1]; box = Box.new(a); box.add("s"); a.last.bytesize; end
    RUBY
    expect(undefined_methods(source)).to eq([])
  end

  it "stays silent after a callee writes a block parameter that holds it" do
    source = <<~RUBY
      def poke(a) = a[0] = "x"
      def m; acc = [7]; [acc].each { |a| poke(a) }; acc[0].upcase; end
    RUBY
    expect(undefined_methods(source)).to eq([])
  end

  # Guards: these never reported, with or without the floor.
  it "stays silent after a returns-self chain on the local (guard)" do
    expect(undefined_methods("def m; a = [1]; a << :x << \"s\"; a.last.bytesize; end\n")).to eq([])
    expect(undefined_methods("def m; a = [1]; a.push(:x).push(\"s\"); a.last.bytesize; end\n")).to eq([])
  end

  describe "precision" do
    it "keeps a literal when nothing escapes" do
      expect(dumped('def m; a = [1]; b = [2]; b << "s"; dump_type(a.size); end')).to eq(["1"])
    end

    it "keeps a literal whose alias is only read" do
      expect(dumped("def m; x = [1]; y = x; y.size; dump_type(x.size); end")).to eq(["1"])
    end

    it "keeps an escaped literal when the receiver is a local that never escapes" do
      expect(dumped('def m; x = [1]; y = [2]; @z = y; x << "s"; dump_type(y.size); end')).to eq(["1"])
    end

    it "keeps an escaped literal when the receiver is another escaped new-object local" do
      source = 'def foo(_) = nil; def m; a = [1]; b = [2]; foo(a); foo(b); b << "s"; dump_type(a.size); end'
      expect(dumped(source)).to eq(["1"])
    end

    it "keeps an escaped literal when the receiver is a method parameter the body never rebinds" do
      expect(dumped('def foo(_) = nil; def m(p); a = [1]; foo(a); p << "s"; dump_type(a.size); end')).to eq(["1"])
    end

    it "keeps a literal handed on only after the mutation" do
      expect(dumped('def m; a = [1]; b = gets.to_s.split; b << "s"; @k = a; dump_type(a.size); end')).to eq(["1"])
    end

    it "keeps a literal passed only to a call that keeps nothing" do
      source = 'def foo(_) = nil; def m; a = [1]; foo(a); b = gets.to_s.split; b << "s"; dump_type(a.size); end'
      expect(dumped(source)).to eq(["1"])
    end

    it "keeps an escaped literal when the receiver is a block parameter of an iterator over literals" do
      expect(dumped("def m; a = [1]; @k = a; [[2]].each { |y| y << 3 }; dump_type(a.size); end")).to eq(["1"])
    end

    it "keeps an escaped literal when the receiver selects between new-object locals" do
      source = "def m; x = [1]; y = [2]; z = [3]; @k = [x, y, z]; (gets ? x : y) << 4; dump_type(z.size); end"
      expect(dumped(source)).to eq(["1"])
    end

    it "keeps the precise reading the named path gives a receiver that is itself aliased" do
      source = 'def m; s = gets.to_s.split(","); t = s; s.map!(&:strip); dump_type(s); end'
      expect(dumped(source)).to eq(["Array[String]"])
    end

    it "keeps the element widening of an element read's aliased root" do
      expect(dumped("def m; c = [{ a: 1 }]; @k = c; c[0].shift; dump_type(c); end")).to eq(["[Hash[Symbol, 1]]"])
    end

    it "floors nothing for a method parameter a callee writes" do
      source = 'def poke(a) = a[0] = "x"; def m(p); r = gets.to_s.split; @k = r; @j = p; poke(p); dump_type(r); end'
      expect(dumped(source)).to eq(["Array[String]"])
    end

    it "keeps an escaped literal String when the receiver is another new String" do
      source = 'def foo(_) = nil; def m; s = +"a"; t = +"b"; foo(s); foo(t); t << "x"; dump_type(s); end'
      expect(dumped(source)).to eq(['"a"'])
    end
  end
end
