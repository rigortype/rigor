# frozen_string_literal: true

# Issue #2515 — a callee that is a top-level `def`. A top-level def is a private method on `Object`, so a receiverless
# call outside any class body, and one inside a class whose chain does not answer the name, runs it. The floor read it
# only for a call at the top level; a call inside a class or method left the caller's hash literal intact, and
# `opts[:k]` reported `flow.always-truthy-condition` on correct code. A def that may not be the one the call runs
# (several defs of the name, an alias, an `Object` reopening, an anonymous class body, a class chain that may answer
# first) reads every argument as written.
require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "a top-level def callee floors the caller's literal (#2515)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-callee-toplevel-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  def rules_of_files(files, config = {})
    files.each do |relative, contents|
      FileUtils.mkdir_p(File.dirname(relative))
      File.write(relative, contents)
    end
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
                                                                           .merge(config))
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
    result.diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  let(:always) { ["flow.always-truthy-condition"] }
  let(:writer) { "def add_default(h)\n  h[:k] = 1\nend" }
  let(:reader) { "def add_default(h)\n  h.to_s\nend" }
  let(:condition) { "puts(:set) if opts[:k]" }

  # `defs` run first, then `body` (statements with a hash literal `opts` in scope that end in a condition on it).
  def top(defs, body) = "#{defs}\nopts = {}\n#{body}\n#{condition}\n"

  def in_class(defs, call, own: "")
    <<~RUBY
      #{defs}
      class Host
        #{own}
        def run
          opts = {}
          #{call}
          #{condition}
        end
      end
    RUBY
  end

  describe "the top-level def writes the argument" do
    it "floors a call at the top level (the pre-existing behaviour, a same-file positive control)" do
      expect(rules(top(writer, "add_default(opts)"))).to eq([])
    end

    it "floors a call inside another top-level def" do
      source = "#{writer}\ndef caller_def\n  opts = {}\n  add_default(opts)\n  #{condition}\nend\n"
      expect(rules(source)).to eq([])
    end

    it "floors a call inside an instance method" do
      expect(rules(in_class(writer, "add_default(opts)"))).to eq([])
    end

    it "floors a call inside a singleton method" do
      source = "#{writer}\nclass Host\n  def self.run\n    opts = {}\n    add_default(opts)\n    " \
               "#{condition}\n  end\nend\n"
      expect(rules(source)).to eq([])
    end

    it "floors a call in a class body" do
      source = "#{writer}\nclass Host\n  opts = {}\n  add_default(opts)\n  #{condition}\nend\n"
      expect(rules(source)).to eq([])
    end

    it "floors a call inside a block in an instance method" do
      expect(rules(in_class(writer, "[1].each { add_default(opts) }"))).to eq([])
    end

    it "floors a call in a subclass whose chain does not define the name" do
      source = "#{writer}\nclass Base\nend\nclass Host < Base\n  def run\n    opts = {}\n    add_default(opts)\n    " \
               "#{condition}\n  end\nend\n"
      expect(rules(source)).to eq([])
    end

    it "floors a keyword argument" do
      defs = "def add_default(into:)\n  into[:k] = 1\nend"
      expect(rules(in_class(defs, "add_default(into: opts)"))).to eq([])
    end

    it "floors a call spelled self.name" do
      expect(rules(in_class(writer, "self.add_default(opts)"))).to eq([])
    end

    it "floors a call spelled send(:name, ...)" do
      expect(rules(in_class(writer, "send(:add_default, opts)"))).to eq([])
    end
  end

  describe "a top-level def hands the argument on to another top-level def" do
    let(:forwarder) { "def forward(h)\n  add_default(h)\nend" }

    it "floors a call at the top level" do
      expect(rules(top("#{writer}\n#{forwarder}", "forward(opts)"))).to eq([])
    end

    it "floors a call inside a class" do
      expect(rules(in_class("#{writer}\n#{forwarder}", "forward(opts)"))).to eq([])
    end

    it "floors through a three-def chain" do
      defs = "#{writer}\n#{forwarder}\ndef outer(h)\n  forward(h)\nend"
      expect(rules(in_class(defs, "outer(opts)"))).to eq([])
    end

    it "floors through a send hand-off" do
      defs = "#{writer}\ndef forward(h)\n  send(:add_default, h)\nend"
      expect(rules(in_class(defs, "forward(opts)"))).to eq([])
    end

    it "floors a hand-off to a top-level def that may not be the one the callee runs" do
      defs = "#{writer}\n#{reader}\ndef forward(h)\n  add_default(h)\nend"
      expect(rules(in_class(defs, "forward(opts)"))).to eq([])
      expect(rules(top(defs, "forward(opts)"))).to eq([])
    end

    it "resolves the callee's own hand-off at the top level and in the caller's class, not in the class alone" do
      defs = "#{writer.sub('add_default', 'push_default')}\ndef forward(h)\n  push_default(h)\nend"
      own = "def push_default(h)\n    h.to_s\n  end"
      expect(rules(in_class(defs, "forward(opts)", own: own))).to eq([])
    end

    it "floors when the hand-off is answered by a same-named instance def of the caller's class" do
      defs = "#{reader}\ndef forward(h)\n  add_default(h)\nend"
      own = "def add_default(h)\n    h[:k] = 1\n  end"
      expect(rules(in_class(defs, "forward(opts)", own: own))).to eq([])
    end
  end

  describe "the top-level def only reads the argument" do
    it "keeps the literal at the top level, so the finding stays" do
      expect(rules(top(reader, "add_default(opts)"))).to eq(always)
    end

    it "keeps the literal inside a class" do
      expect(rules(in_class(reader, "add_default(opts)"))).to eq(always)
    end

    it "keeps the literal for a reader in a class body" do
      source = "#{reader}\nclass Host\n  opts = {}\n  add_default(opts)\n  #{condition}\nend\n"
      expect(rules(source)).to eq(always)
    end

    it "keeps the literal for a reader in a subclass of a class that has other methods" do
      source = "#{reader}\nclass Base\n  def other = 1\nend\nclass Host < Base\n  def run\n    opts = {}\n    " \
               "add_default(opts)\n    #{condition}\n  end\nend\n"
      expect(rules(source)).to eq(always)
    end

    it "keeps the literal for a reader in a subclass of an empty class" do
      source = "#{reader}\nclass Base\nend\nclass Host < Base\n  def run\n    opts = {}\n    " \
               "add_default(opts)\n    #{condition}\n  end\nend\n"
      expect(rules(source)).to eq(always)
    end

    it "keeps the literal through a chain of readers" do
      defs = "#{reader}\ndef forward(h)\n  add_default(h)\nend"
      expect(rules(in_class(defs, "forward(opts)"))).to eq(always)
    end

    it "keeps the literal when no same-named instance def exists for a forwarded call" do
      defs = "#{reader}\ndef forward(h)\n  add_default(h)\nend"
      own = "def other(h)\n    h[:k] = 1\n  end"
      expect(rules(in_class(defs, "forward(opts)", own: own))).to eq(always)
    end

    it "keeps the literal when only the call's other argument is written" do
      defs = "def pair(a, b)\n  b[:k] = 1\nend"
      source = "#{defs}\nclass Host\n  def run\n    opts = {}\n    other = {}\n    pair(opts, other)\n    " \
               "#{condition}\n  end\nend\n"
      expect(rules(source)).to eq(always)
    end

    it "keeps the literal when the redefinition is a visibility toggle only" do
      expect(rules(in_class("#{reader}\npublic :add_default", "add_default(opts)"))).to eq(always)
    end

    it "keeps the literal when Object defines method_missing, which only answers undefined names" do
      defs = "#{reader}\nclass Object\n  def method_missing(name, *args) = super\nend"
      expect(rules(in_class(defs, "add_default(opts)"))).to eq(always)
    end
  end

  describe "the class chain answers the name first" do
    it "keeps the class's own non-writing def authoritative over a writing top-level def" do
      own = "def add_default(h)\n    h.to_s\n  end"
      expect(rules(in_class(writer, "add_default(opts)", own: own))).to eq(always)
    end

    it "keeps a singleton def authoritative on the singleton side" do
      defs = "#{writer}\nclass Host\n  def self.add_default(h) = h.to_s\n  def self.run\n    opts = {}\n    " \
             "add_default(opts)\n    #{condition}\n  end\nend\n"
      expect(rules(defs)).to eq(always)
    end

    it "floors every argument when the class's ancestor is unknown to the project and to RBS" do
      source = "#{reader}\nclass Host < Unknown::Base\n  def run\n    opts = {}\n    add_default(opts)\n    " \
               "#{condition}\n  end\nend\n"
      expect(rules(source)).to eq([])
    end

    it "floors every argument when an RBS ancestor declares the name" do
      source = "def clamp(h)\n  h.to_s\nend\nclass Host\n  include Comparable\n  def run\n    opts = {}\n    " \
               "clamp(opts)\n    #{condition}\n  end\nend\n"
      expect(rules(source)).to eq([])
    end

    # Guard: a literal define_method is also a second ownerless definition row, so the row census floors it as well.
    it "floors every argument when the class defines the name with define_method" do
      own = "define_method(:add_default) { |h| h[:k] = 1 }"
      expect(rules(in_class(reader, "add_default(opts)", own: own))).to eq([])
    end

    it "floors every argument when the class defines method_missing" do
      own = "def method_missing(name, *args) = super"
      expect(rules(in_class(reader, "add_default(opts)", own: own))).to eq([])
    end

    it "floors every argument when the class declares an attr of the name" do
      own = "attr_reader :add_default"
      expect(rules(in_class(reader, "add_default(opts)", own: own))).to eq([])
    end
  end

  describe "the def found may not be the one the call runs" do
    let(:other_writer) { "def other_writer(h)\n  h[:k] = 1\nend" }

    it "floors when the name is defined twice and the last def reads" do
      defs = "#{writer}\n#{reader}"
      expect(rules(in_class(defs, "add_default(opts)"))).to eq([])
      expect(rules(top(defs, "add_default(opts)"))).to eq([])
    end

    it "floors when the name is defined twice with different arities" do
      defs = "def add_default(h)\n  h.to_s\nend\ndef add_default(h, other)\n  other[:k] = 1\nend"
      source = "#{defs}\nclass Host\n  def run\n    opts = {}\n    add_default(1, opts)\n    #{condition}\n  end\nend\n"
      expect(rules(source)).to eq([])
    end

    it "floors when a second file defines the name with a writer" do
      files = { "lib/a.rb" => in_class(reader, "add_default(opts)"), "lib/b.rb" => writer }
      expect(rules_of_files(files)).to eq([])
    end

    it "keeps the finding when the second file defines another name" do
      files = { "lib/a.rb" => in_class(reader, "add_default(opts)"), "lib/b.rb" => "def unrelated(h) = h[:k] = 1" }
      expect(rules_of_files(files)).to eq(always)
    end

    it "floors when Object is reopened with a def of the name" do
      defs = "#{reader}\nclass Object\n  def add_default(h)\n    h[:k] = 1\n  end\nend"
      expect(rules(in_class(defs, "add_default(opts)"))).to eq([])
    end

    it "floors when Object.define_method defines the name" do
      defs = "#{reader}\nObject.define_method(:add_default) { |h| h[:k] = 1 }"
      expect(rules(in_class(defs, "add_default(opts)"))).to eq([])
    end

    it "floors when Object.send(:define_method) defines the name" do
      defs = "#{reader}\nObject.send(:define_method, :add_default) { |h| h[:k] = 1 }"
      expect(rules(top(defs, "add_default(opts)"))).to eq([])
    end

    it "floors when a top-level alias rebinds the name" do
      defs = "#{reader}\n#{other_writer}\nalias add_default other_writer"
      expect(rules(in_class(defs, "add_default(opts)"))).to eq([])
      expect(rules(top(defs, "add_default(opts)"))).to eq([])
    end

    it "floors when alias_method rebinds the name" do
      defs = "#{reader}\n#{other_writer}\nObject.send(:alias_method, :add_default, :other_writer)"
      expect(rules(in_class(defs, "add_default(opts)"))).to eq([])
    end

    it "floors when a mixin is prepended to Object" do
      defs = "module Patch\n  def add_default(h) = h[:k] = 1\nend\nclass Object\n  prepend Patch\nend\n#{reader}"
      expect(rules(in_class(defs, "add_default(opts)"))).to eq([])
    end

    it "keeps the finding when a module is only included at the top level (Object's own method is searched first)" do
      defs = "module Patch\n  def add_default(h) = h[:k] = 1\nend\ninclude Patch\n#{reader}"
      expect(rules(top(defs, "add_default(opts)"))).to eq(always)
    end

    it "floors when the name is a method on main (def self.name)" do
      defs = "#{reader}\ndef self.add_default(h)\n  h[:k] = 1\nend"
      expect(rules(top(defs, "add_default(opts)"))).to eq([])
    end

    it "floors when the only definition of the name sits in an anonymous class body" do
      defs = "Class.new do\n  def add_default(h)\n    h.to_s\n  end\nend"
      expect(rules(top(defs, "add_default(opts)"))).to eq([])
      expect(rules(in_class(defs, "add_default(opts)"))).to eq([])
    end

    it "floors when a conditional def wrote the table slot last" do
      defs = "#{writer}\nif ENV[\"X\"]\n  def add_default(h)\n    h.to_s\n  end\nend"
      expect(rules(in_class(defs, "add_default(opts)"))).to eq([])
    end

    it "floors when a pre_eval: file patches Object with the name" do
      files = { "lib/a.rb" => in_class(reader, "add_default(opts)"),
                "patches/p.rb" => "class Object\n  def add_default(h) = h[:k] = 1\nend\n" }
      expect(rules_of_files(files, "pre_eval" => ["patches/p.rb"])).to eq([])
    end

    it "floors when the only def of the name sits in a block (the table holds it as a possible definer)" do
      source = "def with_block(&block) = block.call\nwith_block do\n  def add_default(h)\n    h.to_s\n  end\nend\n" \
               "opts = {}\nadd_default(opts)\n#{condition}\n"
      expect(rules(source)).to eq([])
    end
  end

  # A floored String is gradual (`Dynamic[String]`): every argument of a FLOOR_EVERY call, written or not, goes through
  # the floor, and the nominal `String` would fail a literal-typed parameter the unmutated local satisfied.
  describe "a floored String argument stays usable where a literal type is expected" do
    let(:signature) do
      { "opener.rbs" => "class Opener\n  def open_with: (\"r\" | \"w\" mode) -> (\"r\" | \"w\")\n  " \
                        "def open_sym: (\"x\" | Symbol mode) -> Symbol\nend\n" }
    end
    let(:twice) { "def helper(x) = x.size\ndef helper(x) = x.size" }

    def mismatches(source)
      analyze(source, sig: signature).diagnostics.map(&:qualified_rule).grep(/argument-type-mismatch/)
    end

    def in_caller(defs, call, header: "class Caller")
      "#{defs}\n#{header}\n  def run\n    mode = \"r\"\n    #{call}\n    Opener.new.open_with(mode)\n  end\nend\n"
    end

    it "fires for a bad literal (the control that the rule is live)" do
      expect(mismatches("Opener.new.open_with(\"x\")\n")).to eq(["call.argument-type-mismatch"])
    end

    it "stays silent for a single non-writing def (same-file control, no floor)" do
      expect(mismatches(in_caller("def helper(x) = x.size", "helper(mode)"))).to eq([])
    end

    it "stays silent for a duplicated def called in a class" do
      expect(mismatches(in_caller(twice, "helper(mode)"))).to eq([])
    end

    it "stays silent for a duplicated def called at the top level" do
      source = "#{twice}\nmode = \"r\"\nhelper(mode)\nOpener.new.open_with(mode)\n"
      expect(mismatches(source)).to eq([])
    end

    it "stays silent for a class with an undeclared ancestor" do
      source = in_caller("def helper(x) = x.size", "helper(mode)", header: "class U < SomeUndeclaredBase")
      expect(mismatches(source)).to eq([])
    end

    it "stays silent for a keyword argument the callee does not take" do
      defs = "def dup1(x, **) = x\ndef dup1(x, **) = x"
      expect(mismatches(in_caller(defs, "dup1(1, mode: mode)"))).to eq([])
    end

    it "stays silent when the only def sits in a block" do
      defs = "[1].each { def inblock(x) = x.size }"
      expect(mismatches(in_caller(defs, "inblock(mode)"))).to eq([])
    end

    it "stays silent in a class that defines method_missing" do
      source = in_caller("def helper(x) = x.size", "helper(mode)",
                         header: "class Caller\n  def method_missing(*) = super")
      expect(mismatches(source)).to eq([])
    end

    it "stays silent for a parameter typed with a literal and a class" do
      source = <<~RUBY
        #{twice}
        class Caller
          def run
            mode = "x"
            helper(mode)
            Opener.new.open_sym(mode)
          end
        end
      RUBY
      expect(mismatches(source)).to eq([])
    end

    # A hand-off resolved by name or to several candidates floors without proof that any one writes: the floor is
    # gradual, the callee's real census stays.
    describe "a union resolution floors the String gradually" do
      let(:signature) { { "sink.rbs" => "class Sink\n  def mode: (\"r\" | \"w\") -> void\nend\n" } }
      let(:defs) do
        "class W; def poke(s) = s << \"x\"; end\nclass R; def poke(s) = s.size; end\n" \
          "def poke(s) = s.size\ndef fwd(s) = poke(s)\ndef via_local(o, s) = o.poke(s)\n"
      end

      def mismatches(source)
        analyze(source, sig: signature).diagnostics.map(&:qualified_rule).grep(/argument-type-mismatch/)
      end

      it "fires for a bad literal (the control that the rule is live)" do
        expect(mismatches("#{defs}Sink.new.mode(\"x\")\n")).to eq(["call.argument-type-mismatch"])
      end

      it "stays silent for a hand-off by name, called inside a class" do
        source = "#{defs}class C\n  def run\n    m = \"r\"\n    fwd(m)\n    Sink.new.mode(m)\n  end\nend\n"
        expect(mismatches(source)).to eq([])
      end

      it "stays silent for a hand-off by name, called at the top level" do
        expect(mismatches("#{defs}m = \"r\"\nfwd(m)\nSink.new.mode(m)\n")).to eq([])
      end

      it "stays silent for a local-receiver union, called inside a class" do
        source = "#{defs}class C\n  def run\n    m = \"r\"\n    via_local(W.new, m)\n    Sink.new.mode(m)\n  end\nend\n"
        expect(mismatches(source)).to eq([])
      end

      it "stays silent for a local-receiver union, called at the top level" do
        expect(mismatches("#{defs}m = \"r\"\nvia_local(Object.new, m)\nSink.new.mode(m)\n")).to eq([])
      end

      it "stays silent for a local-receiver union reached from an instance method of another class" do
        source = "#{defs}class Holder\n  def via_local_m(o, s) = o.poke(s)\nend\nm = \"r\"\n" \
                 "Holder.new.via_local_m(W.new, m)\nSink.new.mode(m)\n"
        expect(mismatches(source)).to eq([])
      end

      it "stays silent for a hand-off by name with a single candidate def" do
        source = "class Only; def poke(s) = s << \"x\"; end\ndef via_one(o, s) = o.poke(s)\nm = \"r\"\n" \
                 "via_one(Only.new, m)\nSink.new.mode(m)\n"
        expect(mismatches(source)).to eq([])
      end

      it "stays silent for a hand-off that resolves to both the singleton and the instance def" do
        source = <<~RUBY
          class Both
            def self.go(s) = s.size
            def go(s) = s << "x"
            def self.wrap(s) = go(s)
            def self.run
              m = "r"
              wrap(m)
              Sink.new.mode(m)
            end
          end
        RUBY
        expect(mismatches(source)).to eq([])
      end

      it "stays silent for a def found on both the singleton and the instance side" do
        source = <<~RUBY
          class Both
            def self.go(s) = s.size
            def go(s) = s << "x"
            def self.run
              m = "r"
              go(m)
              Sink.new.mode(m)
            end
          end
        RUBY
        expect(mismatches(source)).to eq([])
      end
    end

    describe "a def read as written that writes the String keeps the precise floor" do
      let(:signature) { { "sink.rbs" => "class Sink\n  def int: (Integer) -> void\nend\n" } }
      let(:writes) { "def app(s) = s << \"x\"" }

      def found(source)
        rules = analyze(source, sig: signature).diagnostics.map(&:qualified_rule)
        rules.grep(/argument-type-mismatch|undefined-method/)
      end

      it "reports both findings at the top level" do
        source = "#{writes}\nm = \"r\"\napp(m)\nSink.new.int(m)\nm.no_such_method\n"
        expect(found(source)).to eq(%w[call.argument-type-mismatch call.undefined-method])
      end

      it "reports both findings inside a class" do
        source = "#{writes}\nclass Caller\n  def run\n    m = \"r\"\n    app(m)\n    Sink.new.int(m)\n    " \
                 "m.no_such_method\n  end\nend\n"
        expect(found(source)).to eq(%w[call.argument-type-mismatch call.undefined-method])
      end

      it "goes gradual when the writer hands the String to a def that may not be the one called" do
        defs = "def app(s) = other(s)\ndef other(s) = s.size\ndef other(s) = s.size"
        source = "#{defs}\nm = \"r\"\napp(m)\nSink.new.int(m)\nm.no_such_method\n"
        expect(found(source)).to eq([])
      end
    end

    it "stays silent for a non-writing def inherited from a superclass (floor-all)" do
      source = "class Base\n  def inh(x) = x.size\nend\nclass Caller < Base\n  def run\n    mode = \"r\"\n    " \
               "inh(mode)\n    Opener.new.open_with(mode)\n  end\nend\n"
      expect(mismatches(source)).to eq([])
    end
  end

  describe "a variable-arity top-level def that may not be the one called" do
    it "floors an element a splat hands to a rest parameter the def writes" do
      defs = "def add_rest(*rest)\n  rest.first[:k] = 1\nend\ndef add_rest(*rest)\n  rest.size\nend"
      source = "#{defs}\nopts = {}\nargs = [opts]\nadd_rest(*args)\n#{condition}\n"
      expect(rules(source)).to eq([])
    end
  end
end
