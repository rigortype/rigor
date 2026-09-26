# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1359 — `$_`, the last line read, lives in the frame's special-variable slot beside `$~`: a C reader sets its
# caller's `$_` to the line it returns, a condition on one narrows it, and the frame rules decide what may set it.
RSpec.describe Rigor::Inference::LastLine do
  let(:scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }
  let(:string) { Rigor::Type::Combinator.nominal_of("String") }
  let(:line) { scope.with_global(:$_, string) }

  def last_statement(source) = Prism.parse(source).value.statements.body.last
  def root(source) = Prism.parse(source).value

  # The indexed scope and node of the last call named `name` in `source`.
  def indexed_call(source, name, index_scope = scope)
    tree = root(source)
    index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: index_scope)
    calls = []
    tree.breadth_first_search do |node|
      calls << node if node.is_a?(Prism::CallNode) && node.name == name
      false
    end
    [calls.last, index[calls.last]]
  end

  def reads_line?(source, name = :gets)
    call, call_scope = indexed_call(source, name)
    described_class.reads_line?(call, call_scope)
  end

  describe ".reads_line?" do
    it "names a reader on `Kernel`, `ARGF`, `STDIN`, `$stdin` and `$<`" do
      ["Kernel.gets", "::Kernel.gets", "ARGF.gets", "STDIN.gets", "$stdin.gets", "$<.gets",
       "$stdin.readline"].each do |source|
        expect(described_class.reads_line?(last_statement(source), scope)).to be(true), source
      end
    end

    # Issue #1415 (ADR-117 WD5) — an implicit-self or `self.` reader is `Kernel`'s, or a reopened `IO`'s, unless the
    # file shows a `self` whose reader may be Ruby's ({Rigor::Inference::LastLine::ImplicitSelf}). A scope no file
    # index built carries no such evidence, and declines.
    it "names an implicit-self or `self.` reader on the file's evidence about `self`" do
      ["gets", "self.gets", "readline", "self.readline"].each do |source|
        expect(described_class.reads_line?(last_statement(source), scope)).to be(false), source
        expect(reads_line?(source, source.end_with?("readline") ? :readline : :gets)).to be(true), source
      end
      ["def top = gets", "class IO; def first = gets; end", "[1].each { gets }"].each do |source|
        expect(reads_line?(source)).to be(true), source
      end
      ["include Readline\ngets", "o.instance_exec { gets }", "class W < DelegateClass(File); def f = gets; end",
       "def self.gets = 'x'\ngets", "gets { }"].each do |source|
        expect(reads_line?(source)).to be(false), source
      end
    end

    it "does not name another method, a reader given a block, or a reader on a receiver it cannot type" do
      sources = ["$stdin.gets { }", "each_line", "readlines", "io.gets", "$stdout.gets", "@io.gets", "Reader.gets"]
      sources.each do |source|
        expect(described_class.reads_line?(last_statement(source), scope)).to be(false), source
      end
    end

    it "reads a typed receiver by the class RBS places its reader in" do
      expect(reads_line?("io = StringIO.new('a'); io.gets")).to be(true)
      expect(reads_line?("f = File.open('x'); f.readline", :readline)).to be(true)
      # `Kernel#gets` is private: an explicit receiver that only inherits it raises instead of reading.
      expect(reads_line?("o = Object.new; o.gets")).to be(false)
    end

    # RBS declares `Tempfile < File`, but `Tempfile#gets` is `DelegateClass(File)`'s Ruby forwarder, which sets its
    # own frame's `$_` (Ruby 4.0.5: the caller's `$_` stays nil).
    it "does not name `Tempfile`'s reader, which a Ruby forwarder runs" do
      environment = Rigor::Environment.for_project(signature_paths: [])
      project = Rigor::Scope.empty(environment: environment)

      call, call_scope = indexed_call("t = Tempfile.new('x'); t.gets", :gets, project)
      expect(call_scope.type_of(call.receiver).describe(:short)).to eq("Tempfile")
      expect(described_class.reads_line?(call, call_scope)).to be(false)
      file_call, file_scope = indexed_call("f = File.open('x'); f.gets", :gets, project)
      expect(described_class.reads_line?(file_call, file_scope)).to be(true)
    end

    it "reads `$stdin` bound by the file by the type it is bound to" do
      read = last_statement("$stdin.gets")
      reader = Rigor::Type::Combinator.nominal_of("StringIO")
      other = Rigor::Type::Combinator.nominal_of("Object")

      expect(described_class.reads_line?(read, scope.with_global(:$stdin, reader))).to be(true)
      expect(described_class.reads_line?(read, scope.with_global(:$stdin, other))).to be(false)
      expect(described_class.reads_line?(read, scope.with_global(:$stdin, Rigor::Type::Combinator.untyped)))
        .to be(false)
    end

    # Issue #1362 (ADR-117 WD1) — a `$stdin` the file writes is seeded with its declared `IO` joined with the written
    # value, which counts while every member of the union is a core reader's class.
    it "reads a `$stdin` joined from core readers as a reader, and one with any other member as none" do
      project = Rigor::Scope.empty(environment: Rigor::Environment.for_project(signature_paths: []))
      read = last_statement("$stdin.gets")
      io = Rigor::Type::Combinator.nominal_of("IO")
      joined = lambda do |*names|
        members = names.map { |name| Rigor::Type::Combinator.nominal_of(name) }
        project.with_global(:$stdin, Rigor::Type::Combinator.union(io, *members))
      end

      expect(described_class.reads_line?(read, joined.call("StringIO"))).to be(true)
      expect(described_class.reads_line?(read, joined.call("File", "StringIO"))).to be(true)
      expect(described_class.reads_line?(read, joined.call("Tempfile"))).to be(false)
      expect(described_class.reads_line?(read, joined.call("Object"))).to be(false)
      dynamic = Rigor::Type::Combinator.union(io, Rigor::Type::Combinator.untyped)
      expect(described_class.reads_line?(read, project.with_global(:$stdin, dynamic))).to be(false)
    end

    # RBS answers `Kernel` for a reader it leaves out, such as `CSV#gets` (an alias of its Ruby `shift`).
    it "does not name a receiver whose reader RBS places in `Kernel`" do
      project = Rigor::Scope.empty(environment: Rigor::Environment.for_project(signature_paths: []))
      call, call_scope = indexed_call("c = CSV.new($stdin); c.gets", :gets, project)

      expect(call_scope.type_of(call.receiver).describe(:short)).to eq("CSV")
      expect(described_class.reads_line?(call, call_scope)).to be(false)
    end

    # `Kernel`, `STDIN` and `ARGF` are read by their types, so a project constant that shadows one reads by its own.
    it "reads `Kernel`, `STDIN` and `ARGF` by their types" do
      shadowed = scope.with_discovery(
        scope.discovery.with(in_source_constants: { "ARGF" => Rigor::Type::Combinator.nominal_of("Object") })
      )

      expect(described_class.reads_line?(last_statement("ARGF.gets"), shadowed)).to be(false)
      expect(described_class.reads_line?(last_statement("STDIN.gets"), shadowed)).to be(true)
      expect(described_class.reads_line?(last_statement("Object.gets"), scope)).to be(false)
    end

    # The program's own `gets` runs in a frame of its own, and so sets its own `$_`: a reopened `IO`, or a project
    # object another file binds to `$stdin`, reads through it.
    it "names nothing when the program defines a reader of that name anywhere" do
      expect(reads_line?("class IO; def gets = super; end; $stdin.gets")).to be(false)
      expect(reads_line?("class Reader; def gets = 'x'; end; STDIN.gets")).to be(false)
      expect(reads_line?("class Reader; def gets = 'x'; end; $stdin.readline", :readline)).to be(true)
    end
  end

  # A program that puts its own reader in place through the `define_method` family runs that Ruby method, which sets
  # its own frame's `$_` (Ruby 4.0.5: the caller's `$_` stays nil).
  describe ".patched_readers" do
    it "names a reader the `define_method` family puts in place, on any receiver" do
      {
        "STDIN.define_singleton_method(:gets) { }" => [:gets],
        "$stdin.define_singleton_method('readline') { }" => [:readline],
        "STDIN.singleton_class.define_method(:gets) { }" => [:gets],
        "IO.define_method(:gets) { }" => [:gets],
        "alias_method :gets, :to_s" => [:gets],
        "alias gets to_s" => [:gets],
        "IO.send(:define_method, :readline) { }" => [:readline],
        "IO.public_send('alias_method', :gets, :to_s)" => [:gets]
      }.each do |source, names|
        expect(described_class.patched_readers(last_statement(source))).to eq(names), source
      end
    end

    it "names both readers for a computed name, and none for another name or call" do
      ["IO.define_method(name) { }", "alias_method(*names)", "alias :\"\#{x}\" to_s"].each do |source|
        expect(described_class.patched_readers(last_statement(source))).to contain_exactly(:gets, :readline), source
      end
      ["define_method(:each) { }", "alias_method :to_str, :to_s", "IO.send(:puts, :gets)", "IO.send(name, :gets)",
       "define_method(\"\\xff\") { }", "gets"].each do |source|
        expect(described_class.patched_readers(last_statement(source))).to be_nil, source
      end
    end

    it "keeps an explicit reader of a name the file patches in from narrowing, and no other" do
      expect(reads_line?("STDIN.define_singleton_method(:gets) { }\nSTDIN.gets")).to be(false)
      expect(reads_line?("IO.define_method(name) { }\n$stdin.gets")).to be(false)
      expect(reads_line?("STDIN.define_singleton_method(:readline) { }\nSTDIN.gets")).to be(true)
      expect(reads_line?("STDIN.gets")).to be(true)
    end
  end

  describe ".predicate_scopes" do
    it "binds `$_` to the line on each edge: `String` / `nil` for `gets`, `String` for `readline`" do
      truthy, falsey = described_class.predicate_scopes(last_statement("$stdin.gets"), scope, nil)
      expect(truthy.global(:$_)).to eq(string)
      expect(falsey.global(:$_)).to eq(Rigor::Type::Combinator.constant_of(nil))

      truthy, falsey = described_class.predicate_scopes(last_statement("$stdin.readline"), scope, nil)
      expect(truthy.global(:$_)).to eq(string)
      expect(falsey.global(:$_)).to eq(Rigor::Type::Combinator.bot)
    end

    it "layers `$_` over the edges the condition narrows otherwise, and keeps a pair for a non-reader" do
      x_scope = scope.with_local(:x, string)
      truthy, falsey = described_class.predicate_scopes(last_statement("$stdin.gets"), scope, [x_scope, scope])
      expect(truthy.local(:x)).to eq(string)
      expect(truthy.global(:$_)).to eq(string)
      expect(falsey.local(:x)).to be_nil

      pair = [x_scope, scope]
      expect(described_class.predicate_scopes(last_statement("io.gets"), scope, pair)).to equal(pair)
      expect(described_class.predicate_scopes(last_statement("puts"), scope, nil)).to be_nil
    end

    # `io&.gets` answers nil without reading when `io` is nil, which leaves `$_` as it was.
    it "leaves the falsey edge of a safe-navigation reader alone" do
      reader = scope.with_local(:io, Rigor::Type::Combinator.nominal_of("StringIO"))
      truthy, falsey = described_class.predicate_scopes(last_statement("io = nil; io&.gets"), reader, nil)

      expect(truthy.global(:$_)).to eq(string)
      expect(falsey.global(:$_)).to be_nil
    end
  end

  describe ".may_set?" do
    def may_set?(source) = described_class.may_set?(last_statement(source), scope)

    it "counts a reader's name on any receiver, a `send` that may name one, an eval of a String and a write" do
      ["gets", "io.gets", "obj.readline", "IO.foreach(path) { }", "File.foreach(path).to_a", "chomp", "sub(/a/, 'b')",
       "io.send(:gets)", "io.public_send('readline')", "io.send(name)", "eval('x')", "klass.class_eval(src)",
       "$_ = 'x'", "$_ ||= 'x'", "$_, x = 1, 2"].each do |source|
        expect(may_set?(source)).to be(true), source
      end
    end

    it "does not count another method, a `send` naming one, or an eval's block form" do
      ["io.each_line { }", "io.readlines", "io.send(:puts)", "io.send", "klass.class_eval { }", "$x = 1",
       "puts $_", "line.chomp", "line.sub(/a/, 'b')"].each do |source|
        expect(may_set?(source)).to be(false), source
      end
    end

    it "counts a reader in a nested block or lambda, and a block argument that may run one" do
      ["items.each { |i| i.gets }", "items.each { -> { gets } }", "ios.each(&:gets)", "ios.each(&reader)",
       "ios.map(&proc)"].each do |source|
        expect(may_set?(source)).to be(true), source
      end
      ["ios.each(&:chomp)", "ios.each(&)"].each do |source|
        expect(may_set?(source)).to be(false), source
      end
    end

    # A root block reads a slot of its own, a `def` body runs in a frame of its own, and `defined?` runs nothing;
    # a root `&expr` argument's expression runs in the creating frame.
    it "does not count a root block, a `def` body or a `defined?` operand, and counts a root `&expr` operand" do
      ["Thread.new { gets }", "Fiber.new { gets }", "def read = gets", "defined?(gets)"].each do |source|
        expect(may_set?(source)).to be(false), source
      end
      expect(may_set?("Thread.new(&handlers.fetch(gets))")).to be(true)
    end

    it "does not count the method's own `&block` it only forwards" do
      definition = last_statement("def m(&blk) = items.each(&blk)")
      framed = scope.with_match_frame(definition.body, definition.parameters)
      call = definition.body.body.first

      expect(described_class.may_set?(call, framed)).to be(false)
      expect(described_class.may_set?(call, scope)).to be(true)
    end
  end

  describe ".call_rebinds?" do
    def framed(source)
      definition = last_statement(source)
      [definition.body.body, scope.with_match_frame(definition.body, definition.parameters)]
    end

    it "counts a reader, and a call whose block or block argument may run one" do
      body, frame = framed("def m(items); gets; items.each { |i| i.gets }; items.each(&:gets); items.size; end")

      expect(body.map { |call| described_class.call_rebinds?(call, frame) }).to eq([true, true, true, false])
    end

    # A call into a method defined in Ruby sets that method's `$_`, never its caller's.
    it "keeps the narrowing across an implicit-self or explicit call in a frame that hands nothing out" do
      body, frame = framed("def m(items); log('x'); self.log('y'); items.first; items.each { |i| puts i }; end")

      expect(body.map { |call| described_class.call_rebinds?(call, frame) }).to eq([false, false, false, false])
    end

    it "counts every call in a frame that makes a closure that may read, wherever it is written" do
      body, frame = framed("def m(items); items.first; log('x'); f = -> { gets }; f; end")

      expect(described_class.call_rebinds?(body[0], frame)).to be(true)
      expect(described_class.call_rebinds?(body[1], frame)).to be(true)
    end

    it "counts an implicit-self call in a frame that hands out a block that may read, or its own block" do
      body, frame = framed("def m(items); on { gets }; emit; items.first; end")
      expect(body.map { |call| described_class.call_rebinds?(call, frame) }).to eq([true, true, false])

      body, frame = framed("def m(&blk); on(&blk); emit; end")
      expect(described_class.call_rebinds?(body[1], frame)).to be(true)
      body, frame = framed("def m; binding; emit; end")
      expect(described_class.call_rebinds?(body[1], frame)).to be(true)
    end

    it "counts an implicit-self call, and no explicit one, where no body stamped a frame" do
      expect(described_class.call_rebinds?(last_statement("log('x')"), scope)).to be(true)
      expect(described_class.call_rebinds?(last_statement("items.first"), scope)).to be(false)
    end

    it "does not count a thread's or fiber's root block, and counts a root `&expr` operand" do
      body, frame = framed("def m; Thread.new { gets }.join; Fiber.new { gets }; end")
      expect(described_class.call_rebinds?(body[1], frame)).to be(false)
      expect(described_class.block_may_set?(last_statement("Thread.new(&make(gets))"), frame)).to be(true)
      expect(described_class.block_may_set?(last_statement("Thread.new(&handler)"), frame)).to be(false)
    end
  end

  describe ".block_entry" do
    it "forgets `$_` when the body may set it, and keeps it otherwise" do
      reading = last_statement("items.map { |i| r = $_; gets; r }")
      plain = last_statement("items.map { |i| $_ }")

      expect(described_class.block_entry(line, reading.block, reading).global(:$_)).to be_nil
      expect(described_class.block_entry(line, plain.block, plain).global(:$_)).to eq(string)
      expect(described_class.block_entry(scope, reading.block, reading)).to equal(scope)
    end

    it "forgets `$_` when the owning call's operands may set it, which run before the block" do
      call = last_statement("[gets].map { $_ }")

      expect(described_class.block_entry(line, call.block, call).global(:$_)).to be_nil
      expect(described_class.block_entry(line, call.block).global(:$_)).to eq(string)
    end

    # `IO.foreach` sets `$_` to each line before it yields it.
    it "forgets `$_` when the owning call itself sets it" do
      call = last_statement("IO.foreach(path) { $_ }")

      expect(described_class.block_entry(line, call.block, call).global(:$_)).to be_nil
    end

    it "forgets `$_` in a frame that makes a closure that may set it" do
      body = root("f = -> { gets }; items.map { $_ }")
      framed = line.with_match_frame(body)
      call = body.statements.body.last

      expect(described_class.block_entry(framed, call.block, call).global(:$_)).to be_nil
    end
  end

  describe ".forget_if_set" do
    it "forgets a bound `$_` when the body may set it" do
      expect(described_class.forget_if_set(line, last_statement("x = gets")).global(:$_)).to be_nil
      expect(described_class.forget_if_set(line, last_statement("x = 1")).global(:$_)).to eq(string)
      expect(described_class.forget_if_set(scope, last_statement("gets"))).to equal(scope)
      expect(described_class.forget_if_set(line, nil)).to equal(line)
    end
  end
end
