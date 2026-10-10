# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #319 — `Class.new do ... end` evaluates its block as a CLASS BODY (`class_eval` semantics), but the analyzer
# only knew that when the call sat at `Const = ...` rvalue position, where the constant supplied a name to attach the
# body's methods to. Away from that position — `observer_class = Class.new do ... end`, the shape the issue reports —
# the body fell through to top-level scope and produced two false positives on code Ruby runs happily:
#
#   1. `attr_reader` became `call.unresolved-toplevel` (the rule fires on a nil `self_type`, which is what
#      "outside any class or module body" means to `Scope#toplevel?`);
#   2. the class typed as the bare `Singleton[Object]` `class_new_lift` handed back, so `.new(bucket)` was checked
#      against `Object`'s zero-arity `new` and the block's own methods were invisible.
#
# Both halves are asserted here, and each is paired with a still-fires sibling: the two rules are the ones the fix
# touches, so a spec that only asserts silence would pass on a build that had stopped running them.
RSpec.describe "anonymous Class.new block body" do
  def diagnostics_for(source)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "a.rb"), source)
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]),
        cache_store: nil
      )
      guarded_run(runner).diagnostics.reject { |d| d.path.to_s.end_with?(".rigor.yml") }
    end
  end

  def rules_for(source)
    diagnostics_for(source).map(&:rule)
  end

  it "reports nothing for the issue's repro" do
    expect(diagnostics_for(<<~RUBY).map(&:message)).to be_empty
      observer_class = Class.new do
        attr_reader :count

        def initialize(bucket)
          @bucket = bucket
        end
      end
      o = observer_class.new([])
      p o.count
    RUBY
  end

  it "treats a class-level macro in the block as a macro, not as a toplevel call" do
    expect(rules_for(<<~RUBY)).not_to include("call.unresolved-toplevel")
      klass = Class.new do
        attr_reader :count
      end
      p klass
    RUBY
  end

  # The instrument can say "yes": the same macro name genuinely outside any class body still warns.
  it "still warns about a real toplevel macro call" do
    expect(rules_for("attr_reader :count")).to include("call.unresolved-toplevel")
  end

  it "attaches the block's methods to the class the call returns" do
    program = Prism.parse(<<~RUBY).value
      klass = Class.new do
        def alpha
          1
        end
      end
      instance = klass.new
    RUBY
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    scope = index[program.statements.body.first]
    name = Rigor::Inference::AnonymousMetaClass.name_for(program.statements.body.first.value)

    expect(scope.discovered_method?(name, :alpha, :instance)).to be(true)
    expect(scope.user_def_for(name, :alpha)).to be_a(Prism::DefNode)
  end

  # The wrong-arity rule is the one that fired on `observer_class.new([])`. It must still fire where it legitimately
  # did — against a receiver whose arity really is declared.
  it "still reports a genuine arity error against an RBS-known receiver" do
    expect(rules_for("x = Object.new(1)")).to include("call.wrong-arity")
  end

  it "still checks the statements inside the block body" do
    expect(rules_for(<<~RUBY)).to include("call.wrong-arity")
      klass = Class.new do
        BAD = Object.new(1)
      end
    RUBY
  end

  # Surfaced on concurrent-ruby's erlang_actor_spec: a `Module.new { def start; ... end }` is mixed into some
  # other object's `self`, and a sibling block in the same file calls `start` on it. Naming the module's body
  # must not retract the top-level leniency that used to cover that call — the fix would then trade one false
  # positive for another.
  it "keeps a def in an anonymous body reachable from a sibling DSL block in the same file" do
    expect(rules_for(<<~RUBY)).not_to include("call.unresolved-toplevel")
      mixin = Module.new do
        def start
          1
        end
      end
      Kernel.then { start }
      p mixin
    RUBY
  end

  it "leaves `Class.new(Parent) do ... end` typing through its parent" do
    program = Prism.parse(<<~RUBY).value
      klass = Class.new(StandardError) do
        def alpha
          1
        end
      end
    RUBY
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    scope = index[program.statements.body.first]
    call = program.statements.body.first.value
    name = Rigor::Inference::AnonymousMetaClass.name_for(call)

    expect(scope.type_of(call).describe(:short)).to eq("singleton(StandardError)")
    # ... while the block body still records its own methods, and the parent it was given.
    expect(scope.discovered_method?(name, :alpha, :instance)).to be(true)
    expect(scope.superclass_of(name)).to eq("StandardError")
  end

  # Issue #1696 — the same body in a VALUE position: a call argument, a receiver chain, a literal element. The
  # evaluator enters only the statement and assignment forms; the others reach `ScopeIndexer`'s walk of unentered
  # blocks, which left them on the enclosing `self` — at the top level a nil one, so every macro and every implicit-self
  # call in a `def` of the body read as `call.unresolved-toplevel`.
  describe "in a value position (#1696)" do
    def find_node(node, &predicate)
      return node if predicate.call(node)

      node.compact_child_nodes.each do |child|
        found = find_node(child, &predicate)
        return found if found
      end
      nil
    end

    def call_named(program, name) = find_node(program) { |n| n.is_a?(Prism::CallNode) && n.name == name }

    it "reports nothing for the issue's repro" do
      expect(diagnostics_for("Object.const_set(:Other, Class.new { attr_reader :x })\n").map(&:message)).to be_empty
    end

    it "reads the macros and the defs of every class-creating form as a class body" do
      expect(rules_for(<<~RUBY)).not_to include("call.unresolved-toplevel")
        Object.const_set(:Other, Class.new do
          attr_accessor :y
          def hello = y
          private def helper = y
          def self.build = new
        end)
        Object.const_set(:Mixin, Module.new { module_function })
        pairs = [Struct.new(:a) { def b = a }, Data.define(:c) { def d = c }]
        Class.new { attr_reader :z }.new
        p pairs
      RUBY
    end

    it "gives the body the class's self and each def its instance or class self" do
      program = Prism.parse(<<~RUBY).value
        Object.const_set(:Other, Class.new do
          attr_reader :x
          def hello = probe_instance
          def self.build = probe_class
        end)
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
      name = Rigor::Inference::AnonymousMetaClass.name_for(call_named(program, :new))

      expect(index[call_named(program, :attr_reader)].self_type).to eq(Rigor::Type::Combinator.singleton_of(name))
      expect(index[call_named(program, :probe_instance)].self_type).to eq(Rigor::Type::Combinator.nominal_of(name))
      expect(index[call_named(program, :probe_class)].self_type).to eq(Rigor::Type::Combinator.singleton_of(name))
    end

    it "gives a refine block in a value position the refined class's self" do
      program = Prism.parse(<<~RUBY).value
        module Shouting
          p(refine(String) { def shout = probe })
        end
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)

      expect(index[call_named(program, :probe)].self_type).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    # Issue #1689 — `Class` undefines `refine`, so the call in a class body is the class's own method and its block
    # an ordinary one, in a value position as at a statement.
    it "leaves a refine call where self is a class on the enclosing self" do
      program = Prism.parse(<<~RUBY).value
        class Base
          def self.refine(_target) = yield
        end
        class Widget < Base
          p(refine(String) { def shout = probe })
        end
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)

      expect(index[call_named(program, :probe)].self_type).not_to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    # The instrument can say "yes": a genuinely wrong call in a value-position body is still checked.
    it "still reports a genuine error inside a value-position body" do
      rules = rules_for(<<~RUBY)
        Object.const_set(:Other, Class.new do
          BAD = Object.new(1)
          def hello = 1.no_such_method_in_body
        end)
      RUBY
      expect(rules).to include("call.wrong-arity", "call.undefined-method")
    end
  end
end
