# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"

# ADR-116 C4 — `CallLadder::Refined` is the `refined` rung of the call ladder: a call through a Ruby refinement in
# effect at the call site, answered from the winning refine body ahead of every other rung (ADR-121). The examples index
# a snippet, build the site the typer would, and ask the module with a real typer over the snippet's scope. The rung
# reads `typer.scope` and asks the typer back for the refine body's bound arguments and return and, for a member of a
# union no refinement wins, for the call's whole ladder, so what a body types as is the typer's; whether the answer
# reaches a check run is `spec/integration/refined_call_typing_spec.rb`'s.
#
# Most sites below name a method their call node does not, so that an answer read off the node's name differs from
# the one read off the site's: the read of `c[k] += v` is a site whose node is the write and whose name is `[]`.
RSpec.describe Rigor::Inference::CallLadder::Refined do
  let(:combinator) { Rigor::Type::Combinator }
  # `Imp` imports methods the walk cannot name, so any name on a `Rational` may be refined.
  let(:program) do
    Prism.parse(<<~RUBY).value
      module Loud
        refine(String) do
          def shout = :loud
          def whisper = 1
          def echo(x) = x
          def each_yield = yield
          def to_s = :refined
          def [](key) = key
          def me = self
          def tag = :string
          define_method(:built) { 1 }
        end
        refine(Object) do
          def oo = :o
        end
        refine(Integer) { def tag = :integer }
        refine(Float) { def tag = :float }
        refine(Array) { def tag = :array }
        refine(Hash) { def tag = :hash }
      end
      module Imp
        refine(Rational) do
          import_methods Comparable
        end
      end
      s = "a"
      s.shout
      using Loud
      using Imp
      xs = [1, 2].map { it }
      s.shout
      s.plain
      s.respond_to?(:shout)
      s.other(:shout)
      s.map(&:shout)
      s.map(&:plain)
      s.respond_to?(:plain)
      Integer.respond_to?(:oo)
      Integer.sqrt(4)
      s.echo(3)
      s.echo(*xs)
      s.each_yield { :seen }
      s.to_s
      s[:a] += 1
      :last
    RUBY
  end
  let(:statements) { program.statements.body }
  let(:scope) do
    Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty(environment: Rigor::Environment.default))
                                  .fetch(statements.last)
  end
  let(:typer) { Rigor::Inference::ExpressionTyper.new(scope: scope) }
  let(:string) { scope.local(:s) }
  let(:integer) { combinator.nominal_of("Integer") }

  # The statement whose source is `text`, the second of two when `nth` is 1 (`s.shout` before and after `using`).
  def node(text, nth: 0)
    found = []
    Rigor::Source::NodeWalker.each(program) { |candidate| found << candidate if candidate.slice == text }
    found.fetch(nth)
  end

  def site(method_name, call_node, args: [], receiver: string, block_type: nil)
    cc(receiver: receiver, method_name: method_name, args: args, block_type: block_type,
       environment: scope.environment, call_node: call_node, scope: scope)
  end

  def answer(...) = described_class.try_call(site(...), typer)

  describe ".try_call" do
    it "types the call from the winning refine body, not from the method the refinement replaces" do
      expect(string.describe).to eq("String")
      expect(answer(:shout, node("s.shout", nth: 1)).describe).to eq(":loud")
      expect(answer(:to_s, node("s.to_s")).describe).to eq(":refined")
    end

    # `s.plain` names no refined method, so each read of the site's name (the winner, the refine body's `def`) is told
    # apart from a read of the node's: `whisper` asked on the `s.shout` node answers `whisper`'s body, not `shout`'s.
    it "takes the method name from the site, not from the call node" do
      expect(answer(:whisper, node("s.plain")).describe).to eq("1")
      expect(answer(:whisper, node("s.shout", nth: 1)).describe).to eq("1")
      expect(answer(:plain, node("s.shout", nth: 1))).to be_nil
    end

    # The read of `s[:a] += 1` has no call node of its own: the write node stands in, and it has no `name`.
    it "answers the read of a compound index write from the site's name, with the write node as its call node" do
      write = node("s[:a] += 1")

      expect(write).to be_a(Prism::IndexOperatorWriteNode)
      expect(write).not_to respond_to(:name)
      expect(answer(:[], write, args: [combinator.constant_of(:a)]).describe).to eq(":a")
    end

    it "records the site's name as a refinement read, not the call node's" do
      # The snippet is indexed before the recording opens, so the record holds the rung's reads alone.
      plain = site(:whisper, node("s.plain"))
      typer
      record = Rigor::Analysis::DependencyRecorder.record_for("app.rb") { described_class.try_call(plain, typer) }

      expect(record.missing).to include("refinement:whisper")
      expect(record.missing).not_to include("refinement:plain")
    end

    it "takes the receiver from the site" do
      expect(answer(:shout, node("s.shout", nth: 1), receiver: integer)).to be_nil
      expect(answer(:shout, node("s.shout", nth: 1), receiver: combinator.untyped)).to be_nil
    end

    it "takes the argument types from the site, and binds them as the refine body's" do
      expect(answer(:echo, node("s.echo(3)"), args: [combinator.constant_of(3)]).describe).to eq("3")
      expect(answer(:echo, node("s.echo(3)"), args: [combinator.constant_of(:x)]).describe).to eq(":x")
    end

    # `positional_correspondence` reads the call node's own arguments: under a splat the body is bound with no
    # positional correspondence, so `x` is not the array the site's one argument type names.
    it "binds the refine body's parameters by the call node's arguments" do
      array = combinator.nominal_of("Array", type_args: [integer])

      expect(answer(:echo, node("s.echo(*xs)"), args: [array])).to eq(combinator.untyped)
      expect(answer(:echo, node("s.echo(3)"), args: [array]).describe).to eq("Array[Integer]")
    end

    it "takes the block type from the site, and hands it to the refine body as its yield type" do
      seen = combinator.constant_of(:seen)

      expect(answer(:each_yield, node("s.each_yield { :seen }"), block_type: seen)).to eq(seen)
      expect(answer(:each_yield, node("s.each_yield { :seen }"))).to eq(combinator.untyped)
    end

    # The `String` member answers from the refine body; the `Integer` member, which no refinement wins, re-enters the
    # call's ladder with that member as the receiver (`Integer#to_s`). A union no member of which a refinement wins
    # answers nothing, and the rungs below are asked for it whole.
    it "decides a union receiver per member, re-entering the call's ladder for a member no refinement wins" do
      union = combinator.union(string, integer)
      neither = combinator.union(integer, combinator.nominal_of("Symbol"))

      expect(answer(:to_s, node("s.to_s"), receiver: union).describe).to eq(":refined | decimal-int-string")
      expect(answer(:to_s, node("s.to_s"), receiver: neither)).to be_nil
    end

    it "answers `Dynamic[top]` for a name no `def` defines, or one a refinement may define unseen" do
      expect(answer(:built, node("s.plain"))).to eq(combinator.untyped)
      expect(answer(:plain, node("s.plain"), receiver: combinator.nominal_of("Rational"))).to eq(combinator.untyped)
    end

    # `send`, `respond_to?`, `method` and their kin with a literal name, and a `&:name` block, reach the name they
    # spell, which a refinement replaces: they answer `Dynamic[top]` rather than through the arm.
    it "answers `Dynamic[top]` for a call that names a refined method, by the site's name" do
      expect(answer(:respond_to?, node("s.other(:shout)"))).to eq(combinator.untyped)
      expect(answer(:other, node("s.respond_to?(:shout)"))).to be_nil
      expect(answer(:other, node("s.map(&:shout)"))).to eq(combinator.untyped)
      expect(answer(:respond_to?, node("Integer.respond_to?(:oo)"), receiver: combinator.singleton_of("Integer")))
        .to eq(combinator.untyped)
    end

    # A literal name and a `&:name` block are refinement reads of the name they spell, whether or not a refinement
    # replaces it, so a later `refine` of the name in another file re-checks the call.
    it "records the name a naming call or a `&:name` block spells as a refinement read" do
      literal = site(:respond_to?, node("s.respond_to?(:plain)"))
      block = site(:map, node("s.map(&:plain)"), receiver: combinator.nominal_of("Symbol"))
      typer
      reads = [literal, block].map do |asked|
        Rigor::Analysis::DependencyRecorder.record_for("app.rb") { described_class.try_call(asked, typer) }
                                           .missing.grep(/\Arefinement:/)
      end

      expect(reads).to all(include("refinement:plain"))
    end

    # Under `refine(Object) { def oo }` the walk of `Integer`'s singleton levels finds `oo`, and the answer is
    # `Dynamic[top]`, never the refine body's type; a name it does not find keeps the class object's own answer.
    it "answers `Dynamic[top]` for a call on a class object a refinement wins, by the site's name" do
      integer_class = combinator.singleton_of("Integer")

      expect(answer(:oo, node("Integer.sqrt(4)"), receiver: integer_class)).to eq(combinator.untyped)
      expect(answer(:sqrt, node("Integer.sqrt(4)"), receiver: integer_class)).to be_nil
    end

    # The refine body is re-typed with the receiver's class as `self`.
    it "re-types the refine body with the receiver's class as `self`" do
      expect(answer(:me, node("s.plain")).describe).to eq("String")
    end

    # The instance walk reads the class each receiver shape is an instance of: a literal, a tuple, a hash shape, an
    # integer or float range, and a refinement or difference of a class read through its base.
    it "answers for each receiver shape by the class it is an instance of" do
      shapes = [combinator.constant_of("x"), combinator.tuple_of(integer), combinator.hash_shape_of(a: integer),
                combinator.positive_int, combinator.float_range(0.0, 1.0), combinator.non_empty_string,
                combinator.lowercase_string]

      expect(shapes.map { |receiver| answer(:tag, node("s.plain"), receiver: receiver).describe })
        .to eq(%w[:string :array :hash :integer :float :string :string])
    end

    # `Ext` is declared by a signature alone, so no project file says what it refines: where `using Ext` puts it in
    # effect, any method of any instance or class object may be replaced. A `Dynamic` receiver has no lookup to answer.
    it "answers `Dynamic[top]` for every call on an instance or a class object where an opaque module is in effect" do
      Dir.mktmpdir("rigor-refined-rung-") do |dir|
        File.write(File.join(dir, "ext.rbs"), "module Ext\nend\n")
        opaque = Prism.parse("class Box\n  using Ext\n  \"b\".upcase\nend\n:last\n").value
        environment = Rigor::Environment.for_project(signature_paths: [dir])
        empty = Rigor::Scope.empty(environment: environment)
        within = Rigor::Inference::ScopeIndexer.index(opaque, default_scope: empty).fetch(opaque.statements.body.last)
        upcase = opaque.statements.body.first.body.body.last
        ask = lambda do |name, receiver|
          described_class.try_call(cc(receiver: receiver, method_name: name, args: [], environment: environment,
                                      call_node: upcase, scope: within),
                                   Rigor::Inference::ExpressionTyper.new(scope: within))
        end

        expect(within.in_effect_refinements(upcase)).to eq(%w[Ext])
        expect(ask.call(:upcase, combinator.nominal_of("String"))).to eq(combinator.untyped)
        expect(ask.call(:sqrt, combinator.singleton_of("Integer"))).to eq(combinator.untyped)
        expect(ask.call(:upcase, combinator.untyped)).to be_nil
      end
    end

    # A site no refinement is in effect at cannot change its answer without an edit to its own file, so it records no
    # refinement read either.
    it "answers nothing where no refinement is in effect, and records nothing" do
      before = site(:shout, node("s.shout"))
      typer
      found = :unasked
      record = Rigor::Analysis::DependencyRecorder.record_for("app.rb") { found = described_class.try_call(before, typer) }

      expect(found).to be_nil
      expect(record.missing.grep(/\Arefinement:/)).to eq([])
    end
  end

  it "exposes the rung alone, and hides the rest" do
    expect(described_class.singleton_class.public_instance_methods(false)).to contain_exactly(:try_call)
    expect { described_class.refined_receiver_class_name(string) }.to raise_error(NoMethodError, /private/)
  end
end
