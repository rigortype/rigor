# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD10 — `ScopeIndexer::NodePropagation` fills the per-node scope table for the nodes the evaluator did not
# visit. The examples hand it an EMPTY table (so every node is unvisited) and no installed evaluation, so the walk
# alone decides each scope: no runner, no `index`. A scope is read back off the table with the local, instance
# variable or global an example binds in the scope it starts from. `scope_indexer_spec.rb` pins the same behaviour
# through `ScopeIndexer.index`, where the evaluator visits what it can.
RSpec.describe Rigor::Inference::ScopeIndexer::NodePropagation do
  let(:combinator) { Rigor::Type::Combinator }
  let(:scope) { Rigor::Scope.empty }
  let(:string_or_nil) { combinator.union(combinator.nominal_of("String"), combinator.constant_of(nil)) }

  def const(value) = combinator.constant_of(value)

  # `[program, table]` after the walk, from `start` with `recorded` (`{ node => scope }`, found by the block) already
  # in the table.
  def walk(source, start = scope, &recorded)
    program = Prism.parse(source).value
    table = {}.compare_by_identity
    recorded&.call(program)&.each { |node, entry| table[node] = entry }
    described_class.propagate(program, table, start)
    [program, table]
  end

  def last_statement(program) = program.statements.body.last

  context "when a node is not a Prism node" do
    it "records nothing for it" do
      table = {}.compare_by_identity

      expect(described_class.propagate(nil, table, scope)).to be_nil
      expect(table).to be_empty
    end
  end

  describe "inheritance" do
    it "gives every unrecorded node the scope the walk reached it with" do
      program, table = walk("show(a, b + 1)")

      nodes = [program]
      nodes.each { |node| nodes.concat(node.compact_child_nodes) }
      expect(nodes.size).to be > 5
      expect(nodes.map { |node| table.fetch(node) }).to all(equal(scope))
    end

    it "keeps the scope of a recorded node and hands it to the node's children" do
      own = scope.with_local(:o, const(7))
      program, table = walk("show(o)") { |tree| { last_statement(tree) => own } }

      call = last_statement(program)
      expect(table[call]).to equal(own)
      expect(table[call.arguments.arguments.first]).to equal(own)
    end
  end

  describe "the branches of a conditional the evaluator never entered" do
    let(:start) { scope.with_local(:x, string_or_nil) }

    it "narrows an `if` and its `else` by the predicate's edges" do
      program, table = walk("x = 1\nif x then x else x end", start)

      conditional = last_statement(program)
      expect(table[conditional.predicate].local(:x)).to eq(string_or_nil)
      expect(table[conditional.statements.body.first].local(:x)).to eq(combinator.nominal_of("String"))
      expect(table[conditional.subsequent.statements.body.first].local(:x)).to eq(const(nil))
    end

    it "narrows an `unless` the other way round" do
      program, table = walk("x = 1\nunless x then x else x end", start)

      conditional = last_statement(program)
      expect(table[conditional.statements.body.first].local(:x)).to eq(const(nil))
      expect(table[conditional.else_clause.statements.body.first].local(:x)).to eq(combinator.nominal_of("String"))
    end

    it "takes the edges from a scope where a local the predicate writes reads Dynamic[top]" do
      program, table = walk("x = 1\nif show(x = 2) then x else x end", start)

      conditional = last_statement(program)
      expect(table[conditional.statements.body.first].local(:x)).to eq(combinator.untyped)
      expect(table[conditional.subsequent.statements.body.first].local(:x)).to eq(combinator.untyped)
    end

    it "narrows the clauses of a `case` without a subject by its `when` conditions" do
      program, table = walk("x = 1\ncase; when x.nil? then x; else x; end", start)

      node = last_statement(program)
      expect(table[node.conditions.first.statements.body.first].local(:x)).to eq(const(nil))
      expect(table[node.else_clause.statements.body.first].local(:x)).to eq(combinator.nominal_of("String"))
    end

    it "reads a `case` without a subject's clauses from a scope where a local a condition writes is Dynamic[top]" do
      program, table = walk("x = 1\ncase; when show(x = 2) then x; else x; end", start)

      node = last_statement(program)
      expect(table[node.conditions.first.statements.body.first].local(:x)).to eq(combinator.untyped)
      expect(table[node.else_clause.statements.body.first].local(:x)).to eq(combinator.untyped)
    end

    it "reads a `case`'s clauses from a scope where a local its subject writes is Dynamic[top]" do
      program, table = walk("x = 1\ncase show(x = 2) when nil then x else x end", start)

      node = last_statement(program)
      expect(table[node.conditions.first.statements.body.first].local(:x)).to eq(combinator.untyped)
      expect(table[node.else_clause.statements.body.first].local(:x)).to eq(combinator.untyped)
    end

    it "narrows the clauses of a `case` with a subject by the clause's edges" do
      program, table = walk("x = 1\ncase x when nil then x else x end", start)

      node = last_statement(program)
      expect(table[node.conditions.first.statements.body.first].local(:x)).to eq(const(nil))
      expect(table[node.else_clause.statements.body.first].local(:x)).to eq(combinator.nominal_of("String"))
    end

    it "forgets an instance-variable subject from the first `when` test that calls a method" do
      string = combinator.nominal_of("String")
      source = "case @x when String then @x when reset! then @x else @x end"
      program, table = walk(source, scope.with_ivar(:@x, string))

      first, called = last_statement(program).conditions
      expect(table[first.statements.body.first].ivar(:@x)).to eq(string)
      expect(table[called.statements.body.first].ivar(:@x)).to eq(combinator.untyped)
      expect(table[last_statement(program).else_clause.statements.body.first].ivar(:@x)).to eq(combinator.untyped)
    end

    it "forgets a global subject the same way, and keeps one no test calls through" do
      string = combinator.nominal_of("String")
      program, table = walk("case $g when String then $g when reset! then $g end", scope.with_global(:$g, string))

      first, called = last_statement(program).conditions
      expect(table[first.statements.body.first].global(:$g)).to eq(string)
      expect(table[called.statements.body.first].global(:$g)).to eq(combinator.untyped)
    end
  end

  describe "a closure or code body the evaluator never entered" do
    let(:start) { scope.with_local(:o, const(1)).with_local(:k, const(2)) }

    it "rebinds the closure's own locals to Dynamic[top] and keeps a captured one" do
      program, table = walk("o = 1\nk = 2\n->(o) { o + k }", start)

      sum = last_statement(program).body.body.first
      expect(table[sum.receiver].local(:o)).to eq(combinator.untyped)
      expect(table[sum.arguments.arguments.first].local(:k)).to eq(const(2))
    end

    it "leaves a closure local the enclosing scope does not bind unbound" do
      program, table = walk("->(a) { a }", start)

      expect(table[last_statement(program).body.body.first].local(:a)).to be_nil
    end

    it "rebinds an implicit `it` the enclosing scope also binds" do
      program, table = walk("->{ it + 1 }", scope.with_local(:it, const(5)))

      expect(table[last_statement(program).body.body.first.receiver].local(:it)).to eq(combinator.untyped)
    end

    it "gives a block the evaluator entered the scope it was entered with" do
      source = "o = 1\n[1].each { |o| o }"
      entry = scope.with_local(:o, const(7))
      program, table = walk(source, start) { |tree| { last_statement(tree).block => entry } }

      expect(table[last_statement(program).block.body.body.first].local(:o)).to eq(const(7))
    end

    it "rebinds a def's parameters and body locals, not its receiver" do
      program, table = walk("o = 1\ndef r.m(o) = o", start)

      definition = last_statement(program)
      expect(table[definition.receiver].local(:o)).to eq(const(1))
      expect(table[definition.body.body.first].local(:o)).to eq(combinator.untyped)
    end

    it "reads a def's parameter defaults under its own locals" do
      program, table = walk("o = 1\ndef m(o, b = o) = 1", start)

      default = last_statement(program).parameters.optionals.first.value
      expect(table[default].local(:o)).to eq(combinator.untyped)
    end

    it "stops the unknown `self` of an unentered block at a def body" do
      program, table = walk("show(1) { def m = 1; z }")

      block = last_statement(program).block
      definition, read = block.body.body
      expect(table[read].block_self_unknown?).to be(true)
      expect(table[definition.body].block_self_unknown?).to be(false)
    end

    it "records the self each def of a `refine` block runs on" do
      program, table = walk("refine Foo do\n  def m = 1\n  def self.n = 2\n  z\nend")

      instance_def, singleton_def, read = last_statement(program).block.body.body
      expect(table[instance_def].self_type).to eq(combinator.nominal_of("Foo"))
      expect(table[singleton_def].self_type).to be_nil
      expect(table[read].self_type).to be_nil
      expect(table[read].block_self_unknown?).to be(true)
    end

    it "records the self of a `Class.new` block and of its defs" do
      program, table = walk("show(Class.new { def m = 1; def self.n = 2 })")

      call = last_statement(program).arguments.arguments.first
      name = Rigor::Inference::AnonymousMetaClass.name_for(call, nil)
      instance_def, singleton_def = call.block.body.body
      expect(table[call.block.body].self_type).to eq(combinator.singleton_of(name))
      expect(table[instance_def].self_type).to eq(combinator.nominal_of(name))
      expect(table[singleton_def].self_type).to eq(combinator.singleton_of(name))
    end

    it "leaves a block's def the walk reaches on its own, and a def inside a nested block, unrecorded by the class" do
      program, table = walk("show(Class.new { def o.m = 1; [1].each { def n = 2 } })")

      call = last_statement(program).arguments.arguments.first
      name = Rigor::Inference::AnonymousMetaClass.name_for(call, nil)
      receiver_def, each_call = call.block.body.body
      nested_def = each_call.block.body.body.first
      expect(table[receiver_def].self_type).to eq(combinator.singleton_of(name))
      expect(table[nested_def].self_type).not_to eq(combinator.nominal_of(name))
    end

    it "walks a class-body block with no statements" do
      program, table = walk("show(Class.new {})\nrefine Foo do\nend")

      expect(table.size).to be > 4
      expect(table).to have_key(program.statements.body.last.block)
    end

    it "gives a `Class.new` block a scope outside any `class << self` body" do
      program, table = walk("show(Class.new { z })", scope.with_singleton_class_body(true))

      expect(table[last_statement(program).arguments.arguments.first.block.body.body.first].singleton_class_body?)
        .to be(false)
    end

    it "files the defs of a `refine` block in a class body under the class, not the refined class" do
      source = "class W\n  show(refine(String) { def label = 1 })\nend"
      program = Prism.parse(source).value
      table = Rigor::Inference::ScopeIndexer.index(program, default_scope: scope)

      definition = program.statements.body.first.body.body.first.arguments.arguments.first.block.body.body.first
      expect(table[definition].self_type).to eq(combinator.singleton_of("W"))
    end

    it "keeps the scope of a def of a class-body block the evaluator already recorded" do
      source = "refine Foo do\n  def m = 1\nend"
      own = scope.with_local(:o, const(9))
      program, table = walk(source) { |tree| { last_statement(tree).block.body.body.first => own } }

      expect(table[last_statement(program).block.body.body.first]).to equal(own)
    end
  end

  describe "the operands of a call" do
    it "reads a safe-navigation call's arguments under the receiver narrowed to non-nil" do
      program, table = walk("y = 1\ny&.foo(y)", scope.with_local(:y, string_or_nil))

      call = last_statement(program)
      expect(table[call.receiver].local(:y)).to eq(string_or_nil)
      expect(table[call.arguments.arguments.first].local(:y)).to eq(combinator.nominal_of("String"))
    end

    it "does not narrow the arguments of a safe-navigation call whose operands write" do
      program, table = walk("y = 1\ny&.foo((y = nil), y)", scope.with_local(:y, string_or_nil))

      expect(table[last_statement(program).arguments.arguments.last].local(:y)).to eq(string_or_nil)
    end
  end

  describe "an `END` body" do
    it "does not read a guard's narrowing of a global, since it runs after code that may rebind it" do
      string = combinator.nominal_of("String")
      start = scope.with_guarded_global(:$g, string, combinator.untyped)
      program, table = walk("END { $g }", start)

      expect(start.global(:$g)).to eq(string)
      expect(table[last_statement(program).statements.body.first].global(:$g)).not_to eq(string)
    end
  end

  describe "the error globals of a clause the evaluator never entered" do
    let(:start) { scope.with_global(:$!, combinator.nominal_of("StandardError")) }

    it "reads them unbound in a rescue clause and keeps them in the body" do
      program, table = walk("begin; 1; rescue; $!; end", start)

      node = last_statement(program)
      expect(table[node.statements.body.first].global(:$!)).to eq(combinator.nominal_of("StandardError"))
      expect(table[node.rescue_clause.statements.body.first].global(:$!)).to be_nil
    end

    it "reads them unbound in an ensure clause" do
      program, table = walk("begin; 1; ensure; $!; end", start)

      expect(table[last_statement(program).ensure_clause.statements.body.first].global(:$!)).to be_nil
    end

    it "reads them unbound in the rescue expression of a modifier, not in its expression" do
      program, table = walk("y rescue $!", start)

      node = last_statement(program)
      expect(table[node.expression].global(:$!)).to eq(combinator.nominal_of("StandardError"))
      expect(table[node.rescue_expression].global(:$!)).to be_nil
    end
  end

  describe "the evaluation of an unentered construct" do
    def evaluating(source, recorded: nil)
      calls = []
      evaluate = ->(*arguments, **options) { calls << [arguments, options] }
      program = Prism.parse(source).value
      table = {}.compare_by_identity
      recorded&.call(program)&.each { |node| table[node] = scope }
      described_class.with_unentered_evaluator(evaluate) { described_class.propagate(program, table, scope) }
      [program, calls]
    end

    it "hands an unrecorded `&&` to the installed evaluation with the scope it was reached with" do
      program, calls = evaluating("[a && b]")

      node = last_statement(program).elements.first
      expect(calls.map { |arguments, options| [arguments.first, arguments[1], options] }).to eq([[node, scope, {}]])
    end

    it "leaves a construct whose first part the evaluator recorded alone" do
      _program, calls = evaluating("[a && b]", recorded: ->(tree) { [last_statement(tree).elements.first.left] })

      expect(calls).to be_empty
    end

    it "excludes the nodes of a code body in the construct, and answers nil for one without" do
      _program, calls = evaluating("[a && (def m = 1)]")
      _plain, plain_calls = evaluating("[a && b]")

      excluded = calls.first.first.last
      expect(excluded).to be_a(Set)
      expect(excluded.map(&:class)).to include(Prism::DefNode)
      expect(plain_calls.first.first.last).to be_nil
    end

    it "enters the block of an unrecorded value-position call alone" do
      program, calls = evaluating("show([1].map { |e| e })")

      map_call = last_statement(program).arguments.arguments.first
      expect(calls.map { |arguments, options| [arguments.first, options] }).to eq([[map_call, { block_only: true }]])
    end

    it "leaves the block of a call whose block the evaluator recorded alone" do
      _program, calls = evaluating("show([1].map { |e| e })", recorded: lambda { |tree|
        [last_statement(tree).arguments.arguments.first.block]
      })

      expect(calls).to be_empty
    end

    it "hands an unrecorded subjectless `case` to the evaluation by its first `when` test" do
      program, calls = evaluating("[case; when a then 1 end]")

      expect(calls.map { |arguments, _| arguments.first }).to eq([last_statement(program).elements.first])
    end

    it "leaves the block of a class-creating or `refine` call to the walk" do
      _program, class_calls = evaluating("show(Class.new { def m = 1 })")
      _refine, refine_calls = evaluating("refine Foo do\n  def m = 1\nend")

      expect(class_calls).to be_empty
      expect(refine_calls).to be_empty
    end

    it "installs the evaluation for the block only" do
      evaluate = -> {}
      seen = []

      described_class.with_unentered_evaluator(evaluate) { seen << typing_slot(:scope_index_unentered_evaluator) }
      seen << typing_slot(:scope_index_unentered_evaluator)

      expect(seen).to eq([evaluate, nil])
    end
  end

  describe ".refined_class_name" do
    # The `delete_prefix("::")` in the method is a labelled guard: `Source::ConstantPath.qualified_name` renders a
    # rooted path without its `::` and a `Singleton`'s class name carries none, so no input reaches it. Tried a rooted
    # constant, a nested rooted path and a class the environment knows.
    it "names a constant the scope does not type as a class as written, without a leading `::`" do
      target = Prism.parse("::Foo::Bar").value.statements.body.first

      expect(described_class.refined_class_name(target, scope)).to eq("Foo::Bar")
    end
  end

  describe "the interface" do
    it "answers its three entries and keeps every other helper private" do
      expect(described_class.singleton_methods).to contain_exactly(:propagate, :with_unentered_evaluator,
                                                                   :refined_class_name)
    end
  end
end
