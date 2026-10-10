# frozen_string_literal: true

require "spec_helper"

# ADR-121 WD7 (issues #1796, #1799) — the refinement table records what it could not read, so a decline follows from a
# row and never from the absence of one. Every `refine`-shaped node of a project file ends in exactly one outcome of
# `ScopeIndexer.refine_census`; the last example checks that no shape is missed, by counting the nodes independently.
#
# The Ruby behind each row was run on Ruby 4.0.5:
#
# - `[String].each { |k| refine(k) { … } }`, `K = String; refine(K)`, `refine(self)`, `refine(Object.const_get(:S))`,
#   `instance_eval { refine … }`, `M.module_eval { refine … }`, `M.send(:refine, String) { … }`,
#   `M.module_eval("refine(String) { … }")`, `def self.setup = refine(String) { … }`, `class << self; alias_method
#   :my_refine, :refine; end` and `define_method(:my_refine, Module.instance_method(:refine))` there, and
#   `alias my_refine refine` there, each refine for the module named in the row.
# - `module Helper; def setup = refine(String) { … }; end; module N; extend Helper; setup; end; using N` refines
#   for `N`: a `refine` in an instance method runs on whatever module calls it, so it is charged to the wildcard.
# - `refine(String)` with no block raises `ArgumentError: no block given`; `M.refine(String) { }` raises
#   `NoMethodError: private method 'refine' called for module M`; `refine` at the top level raises `NoMethodError`
#   for `main`; `refine(String, &blk)` raises `can't pass a Proc as a block to Module#refine`; a `refine` in a
#   `class` body or a `Class.new` block raises `NoMethodError` (`Class` undefines it, #1689).
# - `refine(String) { refine(Integer) { def twice … } }` runs, but `1.twice` under `using M` raises `NoMethodError`:
#   the nested call refines for the refinement module, so it only makes the outer body's names incomplete.
# - `alias_method :center, :c3`, `alias ljust c3`, `define_method(:rjust) { … }`, `attr_reader :rdr` and
#   `import_methods Helper` in a refine body each define the name on the refined class under `using`.
RSpec.describe Rigor::Inference::ScopeIndexer, ".refine_census" do
  def census(source) = described_class.refine_census(Prism.parse(source).value)

  def wildcard = Rigor::Scope::DiscoveryIndex::REFINEMENT_WILDCARD

  # The calls whose String argument A3 reads, spelled out here rather than read from the engine.
  def string_calls
    %i[
      eval instance_eval class_eval module_eval instance_exec class_exec module_exec send __send__ public_send method
      public_method singleton_method instance_method public_instance_method define_method define_singleton_method
      alias_method
    ]
  end

  # Start offsets of every `refine`-shaped node: a call named `refine` on any receiver, a `:refine` Symbol, and a
  # String holding the word `refine` passed to one of {#string_calls}.
  def refine_shaped_offsets(node, out = [])
    case node
    when Prism::CallNode
      out << node.location.start_offset if node.name == :refine
      refine_string_arguments(node).each { |argument| out << argument.location.start_offset }
    when Prism::SymbolNode
      out << node.location.start_offset if node.unescaped == "refine"
    end
    node.compact_child_nodes.each { |child| refine_shaped_offsets(child, out) }
    out
  end

  def refine_string_arguments(call)
    return [] unless string_calls.include?(call.name)

    (call.arguments&.arguments || []).select do |argument|
      texts = case argument
              when Prism::StringNode then [argument.unescaped]
              when Prism::InterpolatedStringNode then argument.parts.grep(Prism::StringNode).map(&:unescaped)
              else []
              end
      texts.any? { |text| text.match?(/\brefine\b/) }
    end
  end

  any = Rigor::Scope::DiscoveryIndex::REFINEMENT_WILDCARD

  # name => [source, outcomes in source order, the exact refinement table]
  fixtures = {
    "a literal target and block" => [
      "module M\n  refine(String) { def shout = 1 }\nend\n",
      %i[recorded], { "M::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    "a non-literal target in a block (names readable)" => [
      "module M\n  [String, Symbol].each { |k| refine(k) { def center(a, b, c) = 1 } }\nend\n",
      %i[class_unknown], { any => { center: ["M"] } }
    ],
    "a non-literal target whose body's names are incomplete" => [
      "module M\n  [String].each { |k| refine(k) { import_methods Helper } }\nend\n",
      %i[class_unknown], { any => { any => ["M"] } }
    ],
    # A6: the row is normal; the reader treats a key a project constant write binds as the wildcard class.
    "a project constant alias as the target" => [
      "K = String\nmodule M\n  refine(K) { def center(a, b, c) = 1 }\nend\n",
      %i[recorded], { "M::K" => { center: ["M"] }, "K" => { center: ["M"] } }
    ],
    "refine(self)" => [
      "module M\n  refine(self) { def shout = 1 }\nend\n",
      %i[class_unknown], { any => { shout: ["M"] } }
    ],
    "refine(Object.const_get(:S))" => [
      "module M\n  refine(Object.const_get(:S)) { def shout = 1 }\nend\n",
      %i[class_unknown], { any => { shout: ["M"] } }
    ],
    # A6: a constant no table declares keeps a normal row, which matches no receiver and silences nothing.
    "a constant no table declares" => [
      "module M\n  refine(SomeGemClass) { def shout = 1 }\nend\n",
      %i[recorded], { "M::SomeGemClass" => { shout: ["M"] }, "SomeGemClass" => { shout: ["M"] } }
    ],
    "a refine in an instance method" => [
      "module Helper\n  def setup = refine(String) { def shout = 1 }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a def self.x" => [
      "module M\n  def self.setup\n    refine(String) { def shout = 1 }\n  end\nend\n",
      %i[targets_wildcard], { any => { any => ["M"] } }
    ],
    "a refine in a def in class << self" => [
      "module M\n  class << self\n    def setup = refine(String) { def shout = 1 }\n  end\nend\n",
      %i[targets_wildcard], { any => { any => ["M"] } }
    ],
    "a wrapper passing its block through" => [
      "module M\n  def self.my_refine(k, &b) = refine(k, &b)\n  my_refine(String) { def shout = 1 }\nend\n",
      %i[targets_wildcard], { any => { any => ["M"] } }
    ],
    "a refine with a literal target in a block of the module body" => [
      "module M\n  [1].each { refine(String) { def shout = 1 } }\nend\n",
      %i[recorded], { "M::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    "a refine in an implicit instance_eval block" => [
      "module M\n  instance_eval { refine(String) { def shout = 1 } }\nend\n",
      %i[recorded], { "M::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    "a block-form module_eval charges its receiver" => [
      "module L\n  M.module_eval { refine(String) { def shout = 1 } }\nend\n",
      %i[recorded], { "L::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    "a string-form module_eval" => [
      "module L\n  M.module_eval(\"refine(String) { def shout = 1 }\")\nend\n",
      %i[literal], { any => { any => ["L::M", "M"] } }
    ],
    "send(:refine, …) on self" => [
      "module M\n  send(:refine, String) { def shout = 1 }\nend\n",
      %i[literal], { any => { any => ["M"] } }
    ],
    "send(:refine, …) on a constant" => [
      "M.send(:refine, String) { def shout = 1 }\n",
      %i[literal], { any => { any => ["M"] } }
    ],
    "alias_method :my_refine, :refine in class << self" => [
      "module M\n  class << self\n    alias_method :my_refine, :refine\n  end\n  " \
      "my_refine(String) { def shout = 1 }\nend\n",
      %i[literal], { any => { any => ["M"] } }
    ],
    "alias my_refine refine in class << self" => [
      "module M\n  class << self\n    alias my_refine refine\n  end\nend\n",
      %i[literal], { any => { any => ["M"] } }
    ],
    # The receiver of `instance_method` is where the method is taken from, not the module `refine` will run on.
    "define_method(:x, Module.instance_method(:refine))" => [
      "module M\n  class << self\n    define_method(:my_refine, Module.instance_method(:refine))\n  end\nend\n",
      %i[literal], { any => { any => ["M"] } }
    ],
    "a :refine literal at the top level" => [
      "x = Module.private_method_defined?(:refine)\n",
      %i[literal], { any => { any => [any] } }
    ],
    "a refine literal in a method body" => [
      "module M\n  def self.install = send(:refine, String) { def shout = 1 }\nend\n",
      %i[literal], { any => { any => ["M"] } }
    ],
    "a Module.new block written to a constant" => [
      "Ext = Module.new do\n  refine(String) { def shout = 1 }\nend\n",
      %i[recorded], { "String" => { shout: ["Ext"] } }
    ],
    "a refine in a class body" => [
      "class C\n  refine(String) { def label = 1 }\nend\n", %i[dsl], {}
    ],
    "a refine in a Class.new block" => [
      "K = Class.new do\n  refine(String) { def label = 1 }\nend\nClass.new { refine(String) { def other = 1 } }\n",
      %i[dsl dsl], {}
    ],
    "a refine with no block" => [
      "module M\n  refine(String)\nend\n", %i[raises], {}
    ],
    "a refine on another receiver" => [
      "M.refine(String) { def shout = 1 }\n", %i[raises], {}
    ],
    "a Proc passed as the block" => [
      "module M\n  blk = proc { def shout = 1 }\n  refine(String, &blk)\nend\n", %i[raises], {}
    ],
    "a refine with a computed target at the top level" => [
      "refine(k) { def shout = 1 }\n", %i[raises], {}
    ],
    # `twice` is over-recorded on String (the body's `def`s are collected at any depth, as before): the declining
    # direction.
    "a nested refine in a refine body" => [
      "module M\n  refine(String) do\n    refine(Integer) { def twice = 1 }\n    def shout = 1\n  end\nend\n",
      %i[recorded nested],
      { "M::String" => { twice: ["M"], shout: ["M"], any => ["M"] },
        "String" => { twice: ["M"], shout: ["M"], any => ["M"] } }
    ],
    "a refine in a def in a refine body" => [
      "module M\n  refine(Module) do\n    def setup = refine(String) { def shout = 1 }\n  end\nend\n",
      %i[recorded targets_wildcard],
      { "M::Module" => { setup: ["M"] }, "Module" => { setup: ["M"] }, any => { any => [any] } }
    ]
  }

  # Each fixture's outcomes and table, and the census invariant: the nodes counted independently are exactly the
  # nodes the walk accounted for, each once.
  fixtures.each do |name, (source, outcomes, table)|
    it "accounts for #{name}" do
      recorded, accounted = census(source)
      offsets = accounted.map(&:first)

      expect(accounted.map(&:last)).to eq(outcomes)
      expect(recorded).to eq(table)
      expect(offsets.sort).to eq(refine_shaped_offsets(Prism.parse(source).value).sort)
      expect(offsets.uniq.size).to eq(offsets.size)
    end
  end

  # §2.2 — what a fully read refine body may hold, and what makes its names incomplete.
  describe "reading a refine body" do
    def rows(body) = census("module M\n  refine(String) do\n#{body}\n  end\nend\n").first.fetch("String")

    it "records alias, alias_method, define_method, attr_* and undef names (#1799)" do
      expect(rows(<<~RUBY)).to eq(
        def c3(a, b, c) = 1
        alias_method :center, :c3
        alias ljust c3
        define_method(:rjust) { |a, b, c| puts(a) }
        define_method("lstrip", instance_method(:strip))
        attr_reader :rdr
        attr_writer :wtr
        attr_accessor :acc
        undef chop
      RUBY
        { c3: ["M"], center: ["M"], ljust: ["M"], rjust: ["M"], lstrip: ["M"], rdr: ["M"], "wtr=": ["M"],
          acc: ["M"], "acc=": ["M"], chop: ["M"] }
      )
    end

    # `Refinement#target` reads the refined class; on Ruby 4.0.5 `Refinement`'s only other method is `import_methods`.
    it "keeps a body with visibility calls, Refinement#target and a def under a condition fully read" do
      expect(rows(<<~RUBY)).to eq({ a: ["M"], b: ["M"], c: ["M"], d: ["M"] })
        self.target
        private
        def a = 1
        public def b = 1
        private :a, "b"
        protected attr_reader :c
        if RUBY_VERSION > "3"
          def d = 1
        end
        [1].map { |x| x.succ }
      RUBY
    end

    {
      "import_methods" => "import_methods Helper",
      "a computed define_method" => "define_method(name) { 1 }",
      "a computed alias_method" => "alias_method name, :upcase",
      "send" => "send(:define_method, :x) { 1 }",
      "include" => "include Helper",
      "another call on self" => "puts 1",
      "a call on an explicit self" => "self.define_method(name) { 1 }",
      "a call in a condition" => "def x = 1 if respond_to?(:y)"
    }.each do |name, body|
      it "makes the names incomplete for #{name}" do
        expect(rows(body)).to include(wildcard => ["M"])
      end
    end
  end
end
