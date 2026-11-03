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
    "a String method name for send" => 'a = [1]; a.send("push", "s"); a.last.bytesize',
    "a held element of an Array of Arrays" => 'a = [[1]]; @k = [a.first]; @k[0] << "s"; a[0].last.bytesize',
    "a copy made by a conversion that answers the receiver" => 'a = [1]; b = a.to_a; b << "s"; a.last.bytesize',
    "the ivar a local was copied from" => '@q = [1]; a = @q; @q << "s"; a.last.bytesize',
    "another copy of the same ivar" => '@q = [1]; a = @q; b = @q; b << "s"; a.last.bytesize',
    "the global a local was copied from" => '$amf_g = [1]; a = $amf_g; $amf_g << "s"; a.last.bytesize',
    "an ivar set on an earlier pass of a block" => 'a = [1]; [1, 2].each { |i| @h << "s" if i == 2; @h = a }; ' \
                                                   "a.last.bytesize",
    "a proc that runs after the local is handed on" => 'a = [1]; pr = proc { @k << "s" }; @k = a; pr.call; ' \
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

  def flow_rules(source)
    analyze(source).diagnostics.map(&:qualified_rule).grep(/\Aflow\./)
  end

  it "floors a literal String a callee writes through its copy" do
    source = "def app(x) = x << \"b\"\ndef m; s = +\"a\"; t = s; app(t); s == \"ab\" ? 1 : 2; end\n"
    expect(flow_rules(source)).to eq([])
  end

  it "floors a literal Hash a callee writes through its copy" do
    source = "def put(h) = h[:b] = 2\ndef m; h = { a: 1 }; g = h; put(g); h.size == 2 ? 1 : 2; end\n"
    expect(flow_rules(source)).to eq([])
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

  # Review round 1 of #2335 — each body raises in Ruby, and nothing hands the local on: a scalar read, a fresh copy, a
  # read-only alias or an element read of scalars leaves it reachable by no other holder, so its literal stays.
  {
    "a size read" => "n = a.size; @z = []; @z << n",
    "a scalar element read" => "n = a.first; @z = []; @z << n",
    "a predicate" => "e = a.empty?; @z = []; @z << e",
    "a join" => "s = a.join; @z = []; @z << s",
    "a comparison" => "f = (a == [1]); @z = []; @z << f",
    "a dup" => 'b = a.dup; b << "s"',
    "a map" => 'b = a.map(&:to_s); b << "s"',
    "an Array sum" => 'b = a + [2]; b << "s"',
    "a read-only alias" => "b = a; b.size; @z = []; @z << 1",
    "a size read into an unrelated block" => "n = a.size; [[2]].map(&:dup).each { |x| x << n }",
    "a size read as a Hash key" => "{ a.size => 1 }; @z = []; @z << 1",
    "a scalar element in a literal" => "[a.first]; @z = []; @z << 1",
    "a size read in a literal" => "x = [a.size]; @z = []; @z << 1",
    "a shift of a scalar element read out" => "x = a.first; x << 2"
  }.each do |read, body|
    it "still reports a literal after #{read}" do
      expect(undefined_methods("def m; a = [1]; #{body}; a.last.bytesize; end\n")).to eq(["call.undefined-method"])
    end
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
      expect(dumped('def m; a = [1]; b = [2]; @k = a; @j = b; b << "s"; dump_type(a.size); end')).to eq(["1"])
    end

    it "keeps an escaped literal when the receiver is a method parameter the body never rebinds" do
      expect(dumped('def m(p); a = [1]; @k = a; p << "s"; dump_type(a.size); end')).to eq(["1"])
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
      expect(dumped("def m; c = [{ a: 1 }]; @k = c; [1].each { c[0].shift }; dump_type(c); end"))
        .to eq(["[Hash[Symbol, 1]]"])
    end

    it "floors nothing for a method parameter a callee writes" do
      source = 'def poke(a) = a[0] = "x"; def m(p); r = [1].dup; @k = r; @j = p; poke(p); dump_type(r); end'
      expect(dumped(source)).to eq(["[1]"])
    end

    it "keeps an escaped literal when the receiver is a new-object local nothing hands on" do
      expect(dumped("def m; r = [2].dup; @k = r; x = [1]; x << 3; dump_type(r); end")).to eq(["[2]"])
    end

    it "keeps a literal a copy links only after the mutation" do
      expect(dumped('def m; y = [9]; x = [1]; x << "s"; dump_type(y.size); y = x; end')).to eq(["1"])
    end

    it "keeps an escaped literal String when the receiver is another new String" do
      source = 'def m; s = +"a"; t = +"b"; @k = s; @j = t; t << "x"; dump_type(s); end'
      expect(dumped(source)).to eq(['"a"'])
    end
  end
end
