# frozen_string_literal: true

# Issue #2336 — the hand-offs the callee mutation floor did not follow. Each fixture is a correct program in which a
# callee writes the caller's hash literal through a shape the floor could not see, so the caller's
# `options[:format] == "json"` read reported a false `flow.always-truthy-condition`; Ruby (4.0) prints "MUTATED" for
# every row of the first group. The rows that keep the report are the true positives a fix must not lose: Ruby prints
# nothing for them.
require "spec_helper"

RSpec.describe "the callee floor follows the remaining hand-off shapes (#2336)", type: :runner do
  def rules(source)
    analyze(files: { "code.rb" => source }).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  def rules_with_sig(source, sig)
    analyze(files: { "code.rb" => source }, sig: { "code.rbs" => sig })
      .diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }

  # `defs` is more top-level code, `call` the statement of `Caller#own` between the literal and the read, `own` more
  # methods of `Caller`.
  def program(defs, call, own: "")
    <<~RUBY
      class W
        def poke(h) = h[:format] = "json"
        def peek(h) = h.fetch(:format)
      end
      #{defs}
      class Caller
        #{own}
        def own
          options = { format: "text" }
          #{call}
          if options[:format] == "json"
            puts "MUTATED"
          end
        end
      end
    RUBY
  end

  # `body` is `Base#run_it`'s body, which takes `h`; `Base#poke` writes it.
  def instance_program(body, params: "h", call: "Base.new.run_it(options)", extra: "")
    defs = <<~RUBY
      class Base
        def initialize = @w = W.new
        def poke(h) = h[:format] = "json"
        def run_it(#{params})
          #{body}
        end
        #{extra}
      end
    RUBY
    program(defs, call)
  end

  describe "a hand-off to code no def shows reads the argument as written" do
    {
      "a yield into the caller's block" => ["yield(h)", 'Base.new.run_it(options) { |x| x[:format] = "json" }'],
      "a block parameter called with the argument" =>
        ["blk.call(h)", 'Base.new.run_it(options) { |x| x[:format] = "json" }', "h, &blk"],
      "a Method object of a self method" => ["method(:poke).call(h)"],
      "a Method object of the parameter" => ['h.method(:store).call(:format, "json")'],
      "a lambda called with the parameter" => ['->(x) { x.merge!(format: "json") }.call(h)'],
      "a proc called with .()" => ["pr = proc { |x| x[:format] = \"json\" }\n    pr.(h)"],
      "a send whose target is no literal" => ["m = :poke\n    send(m, h)"]
    }.each do |label, (body, call, params)|
      it "follows #{label}" do
        source = instance_program(body, params: params || "h", call: call || "Base.new.run_it(options)")
        expect(rules(source)).to eq([])
      end
    end

    {
      "instance_exec" => ["def run_it(h, &blk) = instance_exec(h, &blk)", "Base.new.run_it(options)"],
      "self.instance_exec" => ["def run_it(h, &blk) = self.instance_exec(h, &blk)", "Base.new.run_it(options)"],
      "class_exec" => ["def self.run_it(h, &blk) = class_exec(h, &blk)", "Base.run_it(options)"],
      "module_exec" => ["def self.run_it(h, &blk) = module_exec(h, &blk)", "Base.run_it(options)"]
    }.each do |label, (defn, call)|
      it "follows #{label} on self running the caller's block" do
        source = program("class Base\n  #{defn}\nend", "#{call} { |x| x[:format] = \"json\" }")
        expect(rules(source)).to eq([])
      end
    end

    it "floors the caller's argument to instance_exec on self" do
      expect(rules(program("", 'instance_exec(options) { |x| x[:format] = "json" }'))).to eq([])
    end

    {
      "an anonymous rest to a block's call" => ["def run_it(*, &b) = b.call(*)", "Base.new.run_it(options)"],
      "an anonymous rest to yield" => ["def run_it(*) = yield(*)", "Base.new.run_it(options)"],
      "an anonymous keyword rest to yield" => ["def run_it(**) = yield(**)", "Base.new.run_it(h: options)", "h:"],
      "... to public_send" => ["def run_it(...) = public_send(...)\n  def poke(h) = h[:format] = \"json\"",
                               "Base.new.run_it(:poke, options)", nil, true]
    }.each do |label, (defn, call, keyword, bare)|
      it "floors through #{label}" do
        block = keyword ? '{ |h:| h[:format] = "json" }' : '{ |x| x[:format] = "json" }'
        source = program("class Base\n  #{defn}\nend", bare ? call : "#{call} #{block}")
        expect(rules(source)).to eq([])
      end
    end

    it "follows a self-call inside a define_method body" do
      defs = "class Base\n  def poke(h) = h[:format] = \"json\"\n  " \
             "def self.setup(h) = define_method(:go) { poke(h) }\nend"
      expect(rules(program(defs, "Base.setup(options); Base.new.go"))).to eq([])
    end

    it "follows a yield into the caller's block through a self-call" do
      expect(rules(program("", 'yielder(options) { |x| x[:format] = "json" }', own: "def yielder(h) = yield(h)")))
        .to eq([])
    end

    it "floors the caller's argument to a Method object's call" do
      expect(rules(program("", "W.new.method(:poke).call(options)"))).to eq([])
    end

    it "floors the caller's argument to a lambda's call" do
      expect(rules(program("", 'pr = ->(x) { x[:format] = "json" }; pr.call(options)'))).to eq([])
    end

    # Guard: a reader handed the parameter through a literal send keeps the true positive.
    it "keeps the literal when a literal send on an ivar hands it to a reader" do
      expect(rules(instance_program("@w.send(:peek, h)"))).to eq(always)
    end

    it "keeps the literal when a string literal send hands it to a reader" do
      expect(rules(instance_program('send("peek", h)', extra: "def peek(h) = h.fetch(:format)"))).to eq(always)
    end
  end

  describe "a send hand-off" do
    {
      "__send__ with a symbol" => "__send__(:poke, h)",
      "send with a string literal" => 'send("poke", h)',
      "send on an ivar" => "@w.send(:poke, h)",
      "send on a constructed receiver" => "W.new.send(:poke, h)",
      "public_send on a local" => "w = W.new; w.public_send(:poke, h)"
    }.each do |label, body|
      it "follows #{label}" do
        expect(rules(instance_program(body))).to eq([])
      end
    end
  end

  describe "a receiver the callee's body does not type" do
    {
      "itself" => "itself.poke(h)",
      "self.class" => "self.class.helper(h)",
      "a constructed instance of self" => "self.class.new.poke(h)",
      "a self-call's result" => "other.poke(h)"
    }.each do |label, body|
      it "follows a call on #{label}" do
        extra = "def self.helper(h) = h[:format] = \"json\"\ndef other = W.new"
        expect(rules(instance_program(body, extra: extra))).to eq([])
      end
    end

    it "follows a call on a call result no type reaches" do
      extra = "def loose = Object.const_get(:W).new"
      expect(rules(instance_program("loose.poke(h)", extra: extra))).to eq([])
    end

    # `itself` resolves exactly: a writing `check` on another class does not floor it, as a by-name reading would.
    it "keeps the literal when a call on itself reaches a reader" do
      extra = "def check(h) = h.fetch(:format)"
      other = "class Other\n  def check(h) = h[:format] = \"json\"\nend\n"
      expect(rules(instance_program("itself.check(h)", extra: extra) + other)).to eq(always)
    end

    it "follows `new.store` in a class method" do
      defs = "class Base\n  def store(h) = h[:format] = \"json\"\n  def self.run(h) = new.store(h)\nend"
      expect(rules(program(defs, "Base.run(options)"))).to eq([])
    end

    it "follows a singleton instance's method" do
      defs = "class Base\n  def helper(h) = h[:format] = \"json\"\n  def self.instance = (@instance ||= new)\n  " \
             "def self.run(h) = instance.helper(h)\nend"
      expect(rules(program(defs, "Base.run(options)"))).to eq([])
    end

    # A self-call `Object` answers in RBS runs that method, so a project `define_method` of the name elsewhere does not
    # floor it.
    it "keeps the literal for a self-call a core method answers" do
      extra = "def run_it2(h) = itself"
      source = "#{instance_program('puts(h)', extra: extra)}class Other\n  " \
               "define_method(:puts) { |h| h[:format] = \"json\" }\nend\n"
      expect(rules(source)).to eq(always)
    end

    # Guard: a name no project def has (a core method) resolves to nothing, so the literal stays.
    it "keeps the literal when the call's name has no project def" do
      expect(rules(instance_program("[].push(h)"))).to eq(always)
    end
  end

  describe "a keyword rest handed on whole" do
    it "follows poke(**kw)" do
      source = program("class Base\n  def poke(h:) = h[:format] = \"json\"\n  def run_it(**kw) = poke(**kw)\nend",
                       "Base.new.run_it(h: options)")
      expect(rules(source)).to eq([])
    end

    # Guard: the keyword rest handed to a reader keeps the literal.
    it "keeps the literal when poke(**kw) only reads" do
      source = program("class Base\n  def peek(h:) = h.fetch(:format)\n  def run_it(**kw) = peek(**kw)\nend",
                       "Base.new.run_it(h: options)")
      expect(rules(source)).to eq(always)
    end
  end

  describe "a callee that returns its parameter" do
    it "floors the caller's argument it may hand back" do
      source = program("class Base\n  def ident(h) = h\nend", 'r = Base.new.ident(options); r[:format] = "json"')
      expect(rules(source)).to eq([])
    end

    it "floors through a hop whose caller writes the result" do
      expect(rules(instance_program('r = ident(h); r[:format] = "json"', extra: "def ident(h) = h"))).to eq([])
    end

    {
      "a part of it" => "def get(h) = h.fetch(:format)",
      "a copy made after a rebind" => "def get(h) = (h = h.dup; h)",
      "a setter's value" => "def get=(h)\n    @h = h\n  end",
      "an index writer's value" => "def []=(k, h)\n    @h = h\n  end",
      "the parameter from a lambda's return" => "def get(h)\n    l = -> { return h }\n    l.call\n    {}\n  end"
    }.each do |label, defn|
      it "keeps the literal when the callee returns #{label}" do
        call = { "get=" => "Base.new.get = options", "[]=" => "Base.new[:k] = options" }
               .find { |key, _| defn.include?(key) }&.last || "Base.new.get(options)"
        expect(rules(program("class Base\n  #{defn}\nend", call))).to eq(always)
      end
    end

    {
      "an explicit return" => "def get(h)\n    return h if h\n    {}\n  end",
      "a write's value" => "def get(h) = (@h ||= h)",
      "the right side of ||" => "def get(h, d = nil) = d || h",
      "the right side of &&" => "def get(h) = h.size && h",
      "a rescue clause's tail" => "def get(h)\n    Integer(\"x\")\n  rescue ArgumentError\n    h\n  end"
    }.each do |label, defn|
      it "floors the caller's argument returned through #{label}" do
        source = program("class Base\n  #{defn}\nend", 'r = Base.new.get(options); r[:format] = "json"')
        expect(rules(source)).to eq([])
      end
    end

    # An operator ending in `=` is no setter: its value is the call's result.
    it "floors the caller's argument a <= operator returns" do
      source = program("class Base\n  def <=(h) = h\nend", 'r = Base.new <= options; r[:format] = "json"')
      expect(rules(source)).to eq([])
    end
  end

  describe "a method body no def table holds" do
    {
      "a module_function def argument" =>
        ["module M\n  module_function def poke(h) = h[:format] = \"json\"\nend", "M.poke(options)"],
      "define_singleton_method" =>
        ["class Base\n  define_singleton_method(:poke) { |h| h[:format] = \"json\" }\nend", "Base.poke(options)"],
      "define_singleton_method behind a self-call" =>
        ["class Base\n  define_singleton_method(:poke) { |h| h[:format] = \"json\" }\n  " \
         "def self.run(h) = poke(h)\nend", "Base.run(options)"],
      "alias_method in class << self" =>
        ["class Base\n  class << self\n    def real(h) = h[:format] = \"json\"\n    alias_method :poke, :real\n  " \
         "end\nend", "Base.poke(options)"],
      "define_method behind a self-call" =>
        ["class Base\n  define_method(:helper) { |h| h[:format] = \"json\" }\n  def run_it(h) = helper(h)\nend",
         "Base.new.run_it(options)"],
      "define_method called directly" =>
        ["class Base\n  define_method(:helper) { |h| h[:format] = \"json\" }\nend", "Base.new.helper(options)"]
    }.each do |label, (defs, call)|
      it "floors through #{label}" do
        expect(rules(program(defs, call))).to eq([])
      end
    end

    # Issue #2336 review — a body the receiver's own class or singleton gets from a definer answers ahead of a
    # same-named core method (`Kernel#select`, `Object#tap`, `Kernel#format`), so the core name does not exempt it.
    {
      "define_singleton_method of a Kernel name" =>
        ["class Svc3\nend\nSvc3.define_singleton_method(:select) { |h| h[:format] = \"json\" }",
         "Svc3.select(options)"],
      "alias_method of a Kernel name in class << self" =>
        ["class Svc2\n  class << self\n    def real_open(h) = h[:format] = \"json\"\n    " \
         "alias_method :open, :real_open\n  end\nend", "Svc2.open(options)"],
      "define_method of an Object name" =>
        ["class Item\nend\nItem.define_method(:tap) { |h| h[:format] = \"json\" }", "Item.new.tap(options)"],
      "define_method of a Kernel name on a constant" =>
        ["class Conn\nend\nConn.define_method(:open) { |h| h[:format] = \"json\" }", "Conn.new.open(options)"],
      "a class-body define_method of a Kernel name" =>
        ["class Svc\n  define_method(:format) { |h| h[:format] = \"json\" }\nend", "Svc.new.format(options)"],
      "a class-body define_method of a Kernel name behind a self-call" =>
        ["class Svc\n  define_method(:format) { |h| h[:format] = \"json\" }\n  def run(h) = format(h)\nend",
         "Svc.new.run(options)"]
    }.each do |label, (defs, call)|
      it "floors through #{label} ahead of the core method" do
        source = program(defs, call)
        expect(rules(source)).to eq([])
      end
    end

    # A definer row may be the receiver's own, which answers ahead of its core method (`Hash#store`).
    it "floors through a definer of a name the receiver's class declares" do
      defs = "class Bag < Hash\nend\nBag.define_method(:store) { |k, h| h[:format] = \"json\" }"
      source = program(defs, "Bag.new.store(:k, options)")
      expect(rules_with_sig(source, "class Bag < ::Hash[untyped, untyped]\nend\n")).to eq([])
    end

    # A top-level def lives on `Object`, so the receiver's own core method (`Hash#store`) answers ahead of it.
    it "keeps the literal when the receiver's class declares the name a top-level def has" do
      defs = "def store(k, v) = v[:format] = \"json\"\nclass Bag < Hash\nend"
      source = program(defs, "Bag.new.store(:k, options)")
      expect(rules_with_sig(source, "class Bag < ::Hash[untyped, untyped]\nend\n")).to eq(always)
    end

    # Guard: a module's plain instance def is not callable on the module; the literal stays.
    it "keeps the literal for a module instance def that is no module function" do
      defs = "module M\n  def poke(h) = h[:format] = \"json\"\nend"
      expect(rules(program(defs, "M.poke(options)"))).to eq(always)
    end
  end

  describe "a hand-off after the parameter is rebound to a copy" do
    {
      "a self-call" => "h = h.dup\n    poke(h)",
      "a zsuper" => "h = h.dup\n    super",
      "a super(h)" => "h = h.dup\n    super(h)"
    }.each do |label, body|
      it "keeps the literal for #{label} of the copy" do
        defs = "class P\n  def run_it(h) = h[:format] = \"json\"\nend\nclass Base < P\n  " \
               "def poke(h) = h[:format] = \"json\"\n  def run_it(h)\n    #{body}\n  end\nend"
        expect(rules(program(defs, "Base.new.run_it(options)"))).to eq(always)
      end
    end

    # Guard: an alias made before the rebind still holds the caller's argument.
    it "floors an alias made before the rebind" do
      expect(rules(instance_program("x = h\n    h = h.dup\n    poke(x)"))).to eq([])
    end
  end

  # Regression rows for shapes earlier changes fixed without a spec of their own.
  describe "shapes already followed" do
    it "follows a yield into the callee's own writing block" do
      expect(rules(instance_program('each_h(h) { |x| x[:format] = "json" }', extra: "def each_h(h) = yield(h)")))
        .to eq([])
    end

    it "floors a parameter a define_method body writes" do
      defs = "class Base\n  def self.setup(h) = define_method(:go) { h[:format] = \"json\" }\nend"
      expect(rules(program(defs, "Base.setup(options); Base.new.go"))).to eq([])
    end

    it "floors a named parameter handed to a zsuper" do
      defs = "class P\n  def run_it(h) = h[:format] = \"json\"\nend\nclass Base < P\n  def run_it(h) = super\nend"
      expect(rules(program(defs, "Base.new.run_it(options)"))).to eq([])
    end
  end
end
