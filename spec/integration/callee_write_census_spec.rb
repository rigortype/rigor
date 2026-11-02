# frozen_string_literal: true

# Issue #2595 — the callee floor's own-def write census missed a shape mutator the content scans do not count
# (`h.merge!`), a write through an alias of the parameter (a local, a block parameter of `tap` or of a container's
# iterator, an ivar), and a hand-off on an ivar receiver. Each left the caller's literal shape intact, so correct code
# reported. Every row calls an own def (`Base.new.run_it(options)`); a pure reader keeps the true positive.
require "spec_helper"

RSpec.describe "the callee write census counts mutators, aliases and ivar hand-offs (#2595)", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  def workspace_rules(source)
    analyze(files: { "code.rb" => source }).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }

  # `body` is `Base#run_it`'s body (parameters `params`); the caller passes a hash literal (or `literal`) through
  # `call` and reads it back. `extra` is more top-level code.
  def program(body, literal: '{ format: "text" }', read: 'options[:format] == "json"', params: "h",
              call: "Base.new.run_it(options)", extra: "")
    <<~RUBY
      class W
        def poke(h) = h[:format] = "json"
        def peek(h) = h.fetch(:format)
      end
      class Base
        def initialize = @w = W.new
        def run_it(#{params})
          #{body}
        end
        def poke(h) = h[:format] = "json"
      end
      class Caller
        def own
          options = #{literal}
          #{call}
          if #{read}
            puts "MUTATED"
          end
        end
      end
      #{extra}
    RUBY
  end

  describe "a shape mutator the content scans do not count" do
    ['merge!(format: "json")', 'update(format: "json")', "transform_values!(&:upcase)"].each do |call|
      it "counts h.#{call}" do
        expect(rules(program("h.#{call}"))).to eq([])
      end
    end

    # A remover only takes things out: the literal opens with every key optional, so a presence test no longer
    # folds, while `options[:format] == "json"` still reports (a remover cannot make the value "json").
    ["compact!", "delete(:format)", "clear", "shift", "keep_if { false }", "select! { false }",
     "reject! { true }"].each do |call|
      it "counts h.#{call} as a remover" do
        expect(rules(program("h.#{call}", read: "options.key?(:format)"))).to eq([])
      end

      it "keeps the report a remover cannot falsify after h.#{call}" do
        expect(rules(program("h.#{call}"))).to eq(always)
      end
    end

    # A remover through an alias may be one on an element the status collapse reads as the parameter, so it floors
    # bare.
    it "floors a remover through an alias bare" do
      expect(rules(program("x = h; x.delete(:format)"))).to eq([])
    end

    # The content adders (`concat`, `push`, `fill`, `replace`, `insert`, `unshift`) were counted before #2595: guards.
    ["pop", "slice!(0)", "delete_at(0)"].each do |call|
      it "counts a.#{call} on an array as a remover" do
        source = program("h.#{call}", literal: '["text"]', read: "options.empty?")
        expect(rules(source)).to eq([])
      end
    end

    ["map!(&:upcase)", "sort!", "reverse!", "rotate!", "shuffle!", "uniq!",
     'concat(["json"])', 'push("json")', 'fill("json")', 'replace(["json"])', 'insert(0, "json")',
     'unshift("json")'].each do |call|
      it "counts a.#{call} on an array" do
        source = program("h.#{call}", literal: '["text"]', read: 'options[0] == "json"')
        expect(rules(source)).to eq([])
      end
    end
  end

  describe "a write through an alias" do
    {
      "a block parameter of tap" => 'h.tap { |x| x[:format] = "json" }',
      "a block parameter of then" => 'h.then { |x| x[:format] = "json" }',
      "a block parameter of yield_self" => 'h.yield_self { |x| x.merge!(format: "json") }',
      "a numbered block parameter" => 'h.tap { _1[:format] = "json" }',
      "an it block parameter" => 'h.tap { it[:format] = "json" }',
      "an element of a container a block iterates" => '[h].each { |x| x[:format] = "json" }',
      "a memo handed to each_with_object" => '[1].each_with_object(h) { |_, m| m[:format] = "json" }',
      "a container iterated with a mutator symbol" => "[h].each(&:clear)",
      "a local alias" => 'other = h; other[:format] = "json"',
      "a local alias of an alias" => 'a = h; b = a; b.merge!(format: "json")',
      "a multiple-assignment alias" => 'a, b = h, 1; a[:format] = "json"',
      "an ivar alias" => '@x = h; @x[:format] = "json"',
      "an instance_variable_set alias" => 'instance_variable_set(:@x, h); @x[:format] = "json"',
      "an opaque dispatch on an alias" => 'other = h; other.send(:store, :format, "json")',
      "a chained assignment alias" => 'x = y = h; y.size; x.merge!(format: "json")',
      "a case value alias" => 'x = case 1 when 1 then h end; x.merge!(format: "json")',
      "a begin value alias" => 'x = begin; h; end; x.merge!(format: "json")',
      "an element of a destructured each_slice" => 'h.each_slice(2) { |a, b| a.merge!(format: "json") }',
      "an element of each_cons' pair" => 'h.each_cons(2) { |prev, cur| cur.merge!(format: "json") }',
      "an element of a numbered each_slice" => 'h.each_slice(2) { _2; _1.merge!(format: "json") }',
      "a destructured memo, which binds nothing" =>
        'h.each_with_object({}) { |pair, (k, v)| v.merge!(format: "json") }',
      "each_with_object's memo before a keyword parameter" =>
        '[1].each_with_object(h) { |e, acc, k: 1| acc.merge!(format: "json") }',
      "each_with_object's only parameter, the element" => 'h.each_with_object({}) { |x| x.merge!(format: "json") }',
      "inject's result, which may be an element" => 'r = h.inject(nil) { |_, x| x }; r.merge!(format: "json")',
      "a rescue clause value alias" => 'x = begin; raise "e"; rescue; h; end; x.merge!(format: "json")',
      "each_with_object's result" => 'x = [1].each_with_object(h) { |_, m| m.size }; x.merge!(format: "json")',
      "each_slice's result with a block" => 'x = h.each_slice(1) { |s| s.size }; x.merge!(format: "json")',
      "a conditional value alias" => 'x = rand > 2 ? h : {}; x.merge!(format: "json")',
      "a self-returner's alias" => 'x = h.itself; x.merge!(format: "json")',
      "a class variable alias" => '@@x = h; @@x.merge!(format: "json")',
      "a global alias" => '$census_g = h; $census_g.merge!(format: "json")',
      "a for loop variable over a container" => 'for x in [h]; x[:format] = "json"; end',
      "an ||= index write on an alias" => 'x = h; x[:format] ||= "json"',
      "an &&= index write on an alias" => 'x = h; x[:format] &&= "json"',
      "an operator index write on an alias" => 'x = h; x[:format] += "x"',
      "an index target on an alias" => 'x = h; x[:format], y = "json", 1',
      "a part of the parameter" => 'v = h[:format]; v << "x"',
      "a block parameter that is a part" => "h.each { |_, v| v.clear }",
      "an element of a copier's result" => "x = h.values; x.each { |v| v.clear }",
      "a container iterated with a mutator symbol through a local" => "t = [h]; t.each(&:clear)"
    }.each do |label, body|
      it "counts #{label}" do
        expect(rules(program(body))).to eq([])
      end
    end
  end

  describe "a mutator whose receiver is an expression" do
    ['(h).merge!(format: "json")', 'h.itself.merge!(format: "json")', 'h.tap {}.merge!(format: "json")',
     '[h].first.merge!(format: "json")', '[h][0][:format] = "json"', '{ k: h }[:k].merge!(format: "json")',
     't = [h]; t[0].merge!(format: "json")', '(rand > 2 ? {} : h).merge!(format: "json")',
     'self.then { h }.merge!(format: "json")', '(h)[:format] = "json"'].each do |body|
      it "counts #{body}" do
        expect(rules(program(body))).to eq([])
      end
    end
  end

  describe "a rest or keyword-rest parameter" do
    {
      "an element written in a block" => 'args.each { |a| a.merge!(format: "json") }',
      "the first element written" => 'args.first.merge!(format: "json")',
      "an element read into a local" => 'x = args[0]; x.merge!(format: "json")',
      "an element taken by a multiple assignment" => 'a, = args; a.merge!(format: "json")'
    }.each do |label, body|
      it "counts #{label} of *args" do
        expect(rules(program(body, params: "*args"))).to eq([])
      end
    end

    it "counts a value of **kw written" do
      source = program('x = kw[:h]; x.merge!(format: "json")', params: "**kw", call: "Base.new.run_it(h: options)")
      expect(rules(source)).to eq([])
    end

    it "counts each value of **kw written" do
      source = program('kw.each_value { |v| v.merge!(format: "json") }', params: "**kw",
                                                                         call: "Base.new.run_it(h: options)")
      expect(rules(source)).to eq([])
    end

    {
      "an element read into a local" => "x = args[0]; poke(x)",
      "each element" => "args.each { |a| poke(a) }",
      "the first element" => "poke(args.first)",
      "an element to an ivar receiver" => "@w.poke(args[0])",
      "the whole rest splatted" => "poke(*args)"
    }.each do |label, body|
      it "follows #{label} of *args handed to a writer" do
        expect(rules(program(body, params: "*args", extra: "# hand-off"))).to eq([])
      end
    end

    # An inherited def is floor-all (#2521): its named rest floors every argument bound to it, as a content parameter
    # does.
    it "floors the arguments an inherited def binds to its rest" do
      source = program("args.size", params: "*args", call: "Sub.new.run_it(options)", extra: "class Sub < Base; end")
      expect(rules(source)).to eq([])
    end

    it "follows a value of **kw handed to a writer" do
      source = program("v = kw[:h]; poke(v)", params: "**kw", call: "Base.new.run_it(h: options)")
      expect(rules(source)).to eq([])
    end

    it "keeps the literal when only the rest array itself is written" do
      expect(rules(program("args.clear", params: "*args"))).to eq(always)
    end
  end

  describe "a hand-off" do
    it "follows an alias handed to a self-call" do
      expect(rules(program("other = h; poke(other)"))).to eq([])
    end

    it "follows a block parameter of tap handed to a self-call" do
      expect(rules(program("h.tap { |x| poke(x) }"))).to eq([])
    end

    it "follows an element of a container handed to a self-call" do
      expect(rules(program("[h].each { |x| poke(x) }"))).to eq([])
    end

    # `to_a` and `to_s` read as the receiver itself, so the result is handed on as the parameter (a part would not be).
    it "follows to_a's result handed to a self-call" do
      expect(rules(program("x = h.to_a; poke(x)"))).to eq([])
    end

    it "follows to_s's result handed to a self-call" do
      expect(rules(program("s = h.to_s; poke(s)"))).to eq([])
    end

    it "follows a memo handed to each_with_object and on to a self-call" do
      expect(rules(program("[1].each_with_object(h) { |_, m| poke(m) }"))).to eq([])
    end

    # Guard: a local receiver typed from `W.new` was already followed (#2515); the row pins it beside the ivar one.
    it "follows a local receiver" do
      expect(rules(program("w = W.new; w.poke(h)"))).to eq([])
    end

    it "follows an ivar receiver by name" do
      expect(rules(program("@w.poke(h)"))).to eq([])
    end

    # Guard: the true positive an ivar hand-off keeps when the named def does not write. Analysed as a workspace of its
    # own, so no other `peek` def in the discovery reaches it.
    it "keeps the literal when the ivar receiver's method only reads" do
      expect(workspace_rules(program("@w.peek(h)"))).to eq(always)
    end

    # Known limit: while a project class has a superclass the table cannot spell (`Struct.new(:a)`), every by-name
    # owner is floor-all (`subclassing_opaque?`), so the reader floors too.
    it "floors the ivar hand-off when a project superclass is opaque" do
      expect(workspace_rules(program("@w.peek(h)", extra: "class Pt < Struct.new(:a); end"))).to eq([])
    end

    # Guard: an alias handed to a reader does not floor.
    it "keeps the literal when an alias is handed to a self-call that only reads" do
      expect(rules(program("other = h; @w.peek(other)"))).to eq(always)
    end
  end

  # Guards: these were counted before #2595 and must stay counted. A direct write the content scans count is left to
  # them (`counts_self`), which keeps their block channel's element type: callee_block_mutation_floor_spec.rb pins it.
  describe "the controls the content scans already counted" do
    {
      "h.store" => 'h.store(:format, "json")',
      "h.replace" => 'h.replace(format: "json")',
      "h.each_key writing h" => 'h.each_key { |k| h[k] = "json" }'
    }.each do |label, body|
      it "still counts #{label}" do
        expect(rules(program(body))).to eq([])
      end
    end
  end

  # The rows a mutation of the fix fails are the copy, rebind and container rows; the plain readers are guards that
  # keep the true positive.
  describe "a pure reader keeps the literal" do
    {
      "h.merge" => "h.merge(other: 1)",
      "h.dup.merge!" => "h.dup.merge!(format: \"json\")",
      "h.to_a" => "h.to_a",
      "h.fetch" => "h.fetch(:format)",
      "h.each without a write" => "h.each { |k, v| puts(k, v) }",
      "h.size" => "h.size",
      "a block parameter of tap that only reads" => "h.tap { |x| x.fetch(:format) }",
      "a local alias that only reads" => "other = h; other.fetch(:format)",
      "a write to a container that holds h" => "t = [h]; t[0] = {}",
      "an alias of a copy" => "x = h.dup; x[:a] = 1",
      "a write after the parameter is rebound to a copy" => "h = h.dup; h[:a] = 1",
      "a shape mutator after the parameter is rebound to a copy" => 'h = h.dup; h.merge!(format: "json")',
      "an alias made after the parameter is rebound to a copy" => 'h = h.dup; x = h; x[:format] = "json"',
      "a write to a slice" => "r = h.slice(:format); r[:b] = 1",
      "a write to transform_values' result" => "r = h.transform_values(&:to_s); r[:x] = 1",
      "a write to the keys" => "r = h.keys; r.sort!",
      "a write to except's result" => 'r = h.except(:a); r.store(:format, "json")',
      "a write to compact's result" => 'r = h.compact; r.merge!(format: "json")',
      "a write to to_h's result with a block" => 'r = h.to_h { |k, v| [k, v] }; r[:format] = "json"',
      "a write to a sorted copy made a hash" => 'r = h.sort.to_h; r[:format] = "json"',
      "a write to group_by's result" => "r = h.group_by { |k, v| v }; r[:format] = 1",
      "a write to filter_map's result" => "r = h.filter_map { |k, v| v }; r << 1",
      "a write to each_with_object's memo" => "h.each_with_object({}) { |(k, v), acc| acc[k] = v }",
      "a write to inject's memo" => "h.inject({}) { |m, (k, v)| m[k] = v; m }",
      "a push to reduce's memo" => "h.reduce([]) { |m, kv| m << kv }",
      "a write to each_with_object's result" => "r = h.each_with_object({}) { |(k, v), m| m[k] = v }; r[:x] = 1",
      "a write to a joined string" => 's = h.to_a.join(","); s << "x"',
      "a write to first(n)'s result" => "r = h.first(1); r << 1",
      "a write to take's result" => "r = h.take(1); r << 1",
      "a write to an each_slice slice" => "h.each_slice(1) { |sl| sl << 1 }"
    }.each do |label, body|
      it "for #{label}" do
        expect(rules(program(body))).to eq(always)
      end
    end
  end
end
