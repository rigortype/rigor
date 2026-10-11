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
# - `module M; def self.setup = refine(String) { def yy = 1 }; end; M.setup; using M; "a".yy` answers `1`, as does a
#   `def` in `class << self`, `def M.setup`, and the same in a module nested in a class: a singleton method of a module
#   runs on the module itself (#1749), so the census records its rows. Without the `M.setup` call `"a".yy` raises
#   `NoMethodError`, and a module that extends `M` does not inherit `M.setup`. `[1].each { refine(String) { … } }`,
#   `tap { … }` and an implicit-self `module_eval { … }` in the method each refine for `M` too, but only the first
#   keeps `self` where the walk can tell, so the others stay a targets-wildcard.
# - A `def self.x` in a refine body defines a method of the refinement, not of the module around it:
#   `module M; refine(String) { def self.setup = refine(Integer) { def twice = 1 } }; end` has no `M.setup`, and
#   calling the refinement's own `setup` refines nothing under `using M` (`1.twice` raises `NoMethodError`).
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
      texts.any? { |text| text.b.match?(/\brefine\b/) }
    end
  end

  def refine_shaped_nodes(node, out = [])
    case node
    when Prism::CallNode
      out << node if node.name == :refine
      out.concat(refine_string_arguments(node))
    when Prism::SymbolNode
      out << node if node.unescaped == "refine"
    end
    node.compact_child_nodes.each { |child| refine_shaped_nodes(child, out) }
    out
  end

  # Nil when the census's outcome for `node` agrees with what the in-effect walk did with it, else what differs.
  def parity_problem(query, node, outcome, charged)
    context = query.refine_context(node)
    return "no context recorded" if context.nil?

    census = Rigor::Inference::RefineSelf
    case outcome
    when :dsl then "a DSL the walk activates" unless context.here == census::CLASS
    when :data then "data the walk charges" unless context.literal == census::CLASS
    when :recorded, :targets_wildcard, :class_unknown then activation_problem(query, node, context, charged)
    when :literal
      expected = census.charged_modules(context, literal: true)
      return nil if (charged.is_a?(Array) && charged.first == :receiver) || Array(charged) == expected

      "literal charged #{charged.inspect}, walk says #{expected.inspect}"
    end
  end

  # `charged` is one module or, where a constant's spelling can denote several, every name.
  def activation_problem(query, node, context, charged)
    expected = Rigor::Inference::RefineSelf.charged_modules(context)
    owners = Array(charged)
    named = owners.none? { |owner| owner.empty? || owner.start_with?("#<") }
    return "charged #{charged.inspect}, walk says #{expected.inspect}" if named && owners != expected
    return nil unless node.block.is_a?(Prism::BlockNode)

    inside = query.at(node.block.location.start_offset + 1)
    wants = owners.map { |owner| owner == wildcard ? Rigor::Inference::InEffectRefinements::UNKNOWN : owner }
    "refine block activates #{inside.inspect}, census charged #{charged.inspect}" if named && !(wants - inside).empty?
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
    # A6, Ruby 4.0.5 prints `:or_assign` and `:const_set_target`: a target the file binds by `||=` or a literal
    # `const_set` names the value written, which the project-wide constant census leaves out.
    "a target the file binds by ||=" => [
      "K ||= String\nmodule M\n  refine(K) { def center(a, b, c) = 1 }\nend\n",
      %i[class_unknown], { any => { center: ["M"] } }
    ],
    # #1749: the project-wide constant census files a constant written in a `class << self` body under no name a
    # `refine` argument spells, but a `def` there reads it lexically. Ruby 4.0.5 prints `1` for `M.setup; using M;
    # "a".yy`.
    "a target a class << self body binds" => [
      <<~RUBY, %i[class_unknown], { any => { center: ["M"] } }
        module M
          class << self
            K = String
            def setup = refine(K) { def center(a, b, c) = 1 }
          end
        end
      RUBY
    ],
    "a target a class << self body binds by a multiple assignment and an operator write" => [
      <<~RUBY, %i[class_unknown] * 4, { any => { center: ["M"], ljust: ["M"], rjust: ["M"], chop: ["M"] } }
        module M
          class << self
            J, K = Symbol, String
            L += 1
            P &&= 1
            def setup
              refine(J) { def center(a, b, c) = 1 }
              refine(K) { def ljust(a, b, c) = 1 }
              refine(L) { def rjust(a, b, c) = 1 }
              refine(P) { def chop(a, b, c) = 1 }
            end
          end
        end
      RUBY
    ],
    "a target a class << self body binds by a path write" => [
      <<~RUBY, %i[class_unknown] * 4, { any => { center: ["M"], ljust: ["M"], rjust: ["M"], chop: ["M"] } }
        module M
          class << self
            self::K = String
            self::L += 1
            self::P &&= 1
            self::J, Q = Symbol, Float
            def setup
              refine(K) { def center(a, b, c) = 1 }
              refine(L) { def ljust(a, b, c) = 1 }
              refine(P) { def rjust(a, b, c) = 1 }
              refine(J) { def chop(a, b, c) = 1 }
            end
          end
        end
      RUBY
    ],
    "a target the file binds by a literal const_set" => [
      "Object.const_set(:K, String)\nmodule M\n  refine(K) { def center(a, b, c) = 1 }\nend\n",
      %i[class_unknown], { any => { center: ["M"] } }
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
    # #1749: a module's singleton method runs on the module, so its rows are recorded as a `refine` in the body's are.
    "a refine in a def self.x" => [
      "module M\n  def self.setup\n    refine(String) { def shout = 1 }\n  end\nend\n",
      %i[recorded], { "M::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    "a refine in a def in class << self" => [
      "module M\n  class << self\n    def setup = refine(String) { def shout = 1 }\n  end\nend\n",
      %i[recorded], { "M::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    "a refine in a def self.x of a module nested in a class" => [
      "class C\n  module M\n    def self.setup = refine(String) { def shout = 1 }\n  end\nend\n",
      %i[recorded],
      { "C::M::String" => { shout: ["C::M"] }, "C::String" => { shout: ["C::M"] }, "String" => { shout: ["C::M"] } }
    ],
    "a refine in a core iterator's block inside a def self.x" => [
      "module M\n  def self.setup = [1].each { refine(String) { def shout = 1 } }\nend\n",
      %i[recorded], { "M::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    "a refine with names it cannot read in a def self.x" => [
      "module M\n  def self.setup = refine(String) { import_methods Helper }\nend\n",
      %i[recorded], { "M::String" => { any => ["M"] }, "String" => { any => ["M"] } }
    ],
    "a nested refine in a refine in a def self.x" => [
      "module M\n  def self.setup\n    refine(String) do\n      refine(Integer) { def twice = 1 }\n      " \
      "def shout = 1\n    end\n  end\nend\n",
      %i[recorded nested],
      { "M::String" => { twice: ["M"], shout: ["M"], any => ["M"] },
        "String" => { twice: ["M"], shout: ["M"], any => ["M"] } }
    ],
    # The rest of a singleton method's `refine`s keep the targets-wildcard: a target the walk cannot name, a receiver
    # spelled by its constant (the name matches by its last segment only), a block that may rebind `self`, an eval
    # (the walk charges what the eval names), and a `define_singleton_method` block. Each refines for `M` on Ruby
    # 4.0.5 once the method runs, so `M` is opaque and nothing else is.
    "a refine with a computed target in a def self.x" => [
      "module M\n  def self.setup(k) = refine(k) { def shout = 1 }\nend\n",
      %i[targets_wildcard], { any => { any => ["M"] } }
    ],
    "a refine in a def M.x" => [
      "module M\n  def M.setup = refine(String) { def shout = 1 }\nend\n",
      %i[targets_wildcard], { any => { any => ["M"] } }
    ],
    "a refine in a block that may rebind self inside a def self.x" => [
      "module M\n  def self.setup = tap { refine(String) { def shout = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in an implicit module_eval block inside a def self.x" => [
      "module M\n  def self.setup = module_eval { refine(String) { def shout = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => ["M"] } }
    ],
    # A `Module` subclass's singleton method runs on the class, which has no `refine` (#1689), as a plain class's does.
    "a refine in a def self.x of a Module subclass" => [
      "class MyMod < Module\n  def self.setup = refine(String) { def shout = 1 }\nend\n", %i[dsl], {}
    ],
    # A singleton method defined in a refine body belongs to the refinement, whichever module the body is written in.
    # Ruby 4.0.5 runs the `refine` there on the `Refinement`, which `using` rejects with `TypeError`, so it can reach no
    # `using` span and is charged to nothing; `1.twice` raises `NoMethodError` even under `using M`.
    "a refine in a def self.x in a refine body" => [
      <<~RUBY, %i[recorded nested], {}
        module M
          refine(String) do
            def self.setup = refine(Integer) { def twice = 1 }
          end
        end
      RUBY
    ],
    # `define_singleton_method` is a call on the refinement the body reader cannot follow, so the body's names are
    # incomplete (and `twice`, a `def` at any depth, is over-recorded, as for a nested refine).
    "a refine in a define_singleton_method block in a refine body" => [
      <<~RUBY, %i[recorded nested], { "M::String" => { any => ["M"], twice: ["M"] }, "String" => { any => ["M"], twice: ["M"] } }
        module M
          refine(String) do
            define_singleton_method(:setup) { refine(Integer) { def twice = 1 } }
          end
        end
      RUBY
    ],
    "a refine in a def in a class << self body in a refine body" => [
      <<~RUBY, %i[recorded nested], {}
        module M
          refine(String) do
            class << self
              def setup = refine(Integer) { def twice = 1 }
            end
          end
        end
      RUBY
    ],
    "a :refine literal in a def self.x in a refine body" => [
      <<~RUBY, %i[recorded nested nested nested], {}
        module M
          refine(String) do
            def self.setup = send(:refine, Integer) { def twice = 1 }
            def self.other = alias_method(:my_refine, :refine)
            def self.third = [:refine]
          end
        end
      RUBY
    ],
    # The refine block's own module is several names (an eval on a constant in `module L`) or the walk's name for a bare
    # `Module.new`; its singleton methods are still the refinement's.
    # Ruby 4.0.5 runs both on the `Refinement` too (`using` rejects it, `1.ii` and `1.jj` raise `NoMethodError`): an
    # eval on `self` in the refinement's singleton method, and a refine body written in a module's own singleton method.
    "a refine in an eval block on self in a singleton method of a refine body" => [
      <<~RUBY, %i[recorded nested], {}
        module M
          refine(String) do
            def self.h = module_eval { refine(Integer) { def ii = 1 } }
          end
        end
      RUBY
    ],
    "a refine in a singleton method of a refine body written in a module's singleton method" => [
      <<~RUBY, %i[recorded nested], { "M::String" => { yy: ["M"] }, "String" => { yy: ["M"] } }
        module M
          def self.setup
            refine(String) do
              def yy = 1
              def self.h = refine(Integer) { def ii = 1 }
            end
          end
        end
      RUBY
    ],
    "a refine in a singleton method of a refine body nested in a refinement's singleton method" => [
      <<~RUBY, %i[recorded nested nested], {}
        module M
          refine(String) do
            def self.h = refine(Integer) { def self.k = refine(Float) { def ff = 1 } }
          end
        end
      RUBY
    ],
    "a refine in a def self.x in a refine body of an eval block on a constant" => [
      <<~RUBY, %i[recorded nested], {}
        module L
          M.module_eval do
            refine(String) { def self.setup = refine(Integer) { def twice = 1 } }
          end
        end
      RUBY
    ],
    "a refine in a def self.x in a refine body of a bare Module.new block" => [
      <<~RUBY, %i[recorded nested], {}
        Module.new do
          refine(String) { def self.setup = refine(Integer) { def twice = 1 } }
        end
      RUBY
    ],
    "a wrapper passing its block through" => [
      "module M\n  def self.my_refine(k, &b) = refine(k, &b)\n  my_refine(String) { def shout = 1 }\nend\n",
      %i[targets_wildcard], { any => { any => ["M"] } }
    ],
    "a refine with a literal target in a block of the module body" => [
      "module M\n  [1].each { refine(String) { def shout = 1 } }\nend\n",
      %i[recorded], { "M::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    # Ruby 4.0.5: `module Helper; define_method(:setup) { refine(String) { … } }; end; module N; extend Helper; setup;
    # end; using N` refines for `N`, so a `define_method` block on the instance side is charged to the wildcard.
    "a refine in a define_method block" => [
      "module Helper\n  define_method(:setup) { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a define_singleton_method block" => [
      "module N\n  define_singleton_method(:setup) { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => ["N"] } }
    ],
    # Ruby 4.0.5: `Ext.define { refine(String) { … } }` at the top level, with `def self.define(&blk) =
    # module_eval(&blk)`, refines for `Ext`; at the top level a block may run under any module.
    "a refine in a top-level block an eval may run" => [
      "module Ext\n  def self.define(&blk) = module_eval(&blk)\nend\nExt.define do\n  " \
      "refine(String) { def center(a, b, c) = 1 }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    # Ruby 4.0.5: `Registry.refining(Ext) { refine(String) { … } }` in `module Setup`, with `def self.refining(mod,
    # &blk) = mod.module_eval(&blk)`, refines for `Ext`, not `Setup`.
    "a refine in a block another module's DSL may run" => [
      "module Setup\n  Registry.refining(Ext) { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a lambda" => [
      "module M\n  BODY = -> { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    # R2: inside a method body a block follows the same rule as in a module body. Ruby 4.0.5 prints `:installed`,
    # `:class_installed`, `:in_def_dsl`, `:const_eval`, `:iexec`, `:nested_dsm` and `:nested_def` for these refines,
    # each refining for `Ext`, not the module or class the method is written in.
    "a refine in an eval block on a parameter inside a def self.x" => [
      "module Installer\n  def self.install(mod) = mod.module_eval { refine(String) { def center(a, b, c) = 1 } }\n" \
      "end\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in an eval block on a parameter inside a class's def self.x" => [
      "class Installer\n  def self.install(mod) = mod.module_eval { refine(String) { def center(a, b, c) = 1 } }\n" \
      "end\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a DSL block inside a def self.x" => [
      "module Setup\n  def self.run = Registry.refining(Ext) { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in an eval block on a constant inside a def self.x" => [
      "module Installer\n  def self.install = Ext.module_eval { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => ["Installer::Ext", "Ext"] } }
    ],
    "a refine in an instance_exec block on a parameter inside a def self.x" => [
      "module Installer\n  def self.install(mod) = mod.instance_exec { refine(String) { def center(a, b, c) = 1 } }\n" \
      "end\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a define_singleton_method block inside a DSL block" => [
      "module Setup\n  Registry.refining(Ext) do\n    define_singleton_method(:install) do\n      " \
      "refine(String) { def center(a, b, c) = 1 }\n    end\n  end\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a def self.x inside a DSL block" => [
      "module Setup\n  Registry.refining(Ext) do\n    " \
      "def self.install = refine(String) { def center(a, b, c) = 1 }\n  end\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    # R2-M1: a core iteration method on a constant this file binds to a literal never rebinds `self`, so the rows
    # stay `M`'s.
    "a refine in a core iterator's block on a constant" => [
      "module M\n  TARGETS = [String, Symbol].freeze\n  " \
      "TARGETS.each { |k| refine(k) { def center(a, b, c) = 1 } }\nend\n",
      %i[class_unknown], { any => { center: ["M"] } }
    ],
    # R3-S2: a core iteration method keeps `self` only on a receiver whose value is a literal in this file. Ruby
    # 4.0.5 prints `:local_lit`, `:ivar_lit` and `:rebound` for the first two, `M`'s and `Ext`'s, and `:config_each`,
    # `:local_each`, `:array_configure` and `:times` for the four shapes after them, each refining for `Ext`.
    "a refine in a core iterator's block on a local and an ivar bound to literals" => [
      "module M\n  targets = [String]\n  targets.each { |k| refine(k) { def center(a, b, c) = 1 } }\n  " \
      "@targets = [String]\n  @targets.each { |k| refine(k) { def ljust(a, b, c) = 1 } }\nend\n",
      %i[class_unknown class_unknown], { any => { center: ["M"], ljust: ["M"] } }
    ],
    "a refine in a core iterator's block on a local the file binds to another value" => [
      "module N\n  runner = [1]\n  2.times do |i|\n    runner.each { refine(String) { def chop(a, b, c) = 1 } }\n    " \
      "runner = Runner.new\n  end\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    # Ruby 4.0.5 prints `:param`, `:multi`, `:const_set` and `:path_write`, each refining for `Ext` through a
    # `Runner#each` that runs `Ext.module_eval(&blk)`, and `[true, false]` for where `class << self` puts its constant
    # (`singleton_class.const_defined?(:TARGETS, false)`, then `const_defined?(:TARGETS, false)`).
    "a refine in a core iterator's block on a parameter of a literal-bound local's name" => [
      "module P\n  targets = [String]\n  " \
      "def self.setup(targets) = targets.each { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a core iterator's block on a constant a multiple assignment rebinds" => [
      "module Q\n  TARGETS = [String]\n  TARGETS, = [Runner.new]\n  " \
      "TARGETS.each { refine(String) { def ljust(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a core iterator's block on a constant a const_set rebinds" => [
      "module Q\n  TARGETS = [String]\n  const_set(:TARGETS, Runner.new)\n  " \
      "TARGETS.each { refine(String) { def rjust(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a core iterator's block on a constant a path write rebinds" => [
      "module Q\n  TARGETS = [String]\n  Q::TARGETS = Runner.new\n  " \
      "TARGETS.each { refine(String) { def chop(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a core iterator's block on a constant only class << self binds" => [
      "module S\n  class << self\n    TARGETS = [String]\n  end\n  " \
      "TARGETS.each { refine(String) { def rjust(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a core iterator's block on a module a project method defines it for" => [
      "module Config\n  def self.each(&blk) = Ext.module_eval(&blk)\nend\nmodule Setup\n  " \
      "Config.each { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a core iterator's block on a local holding a project object" => [
      "module Setup\n  runner = Runner.new(Ext)\n  runner.each { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in another method's block on a literal" => [
      "module Setup\n  [1].configure { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    "a refine in a core iterator's block on a module with no literal write" => [
      "module Count\n  def self.times(&blk) = Ext.module_eval(&blk)\nend\nmodule Setup\n  " \
      "Count.times { refine(String) { def center(a, b, c) = 1 } }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
    ],
    # R2-M2: a block on a literal inside a plain class's method keeps the class: data, and the class's own `refine`
    # (Ruby 4.0.5 prints `[:show, :show]`, `[10, 20]` and `2`).
    "a :refine Symbol in a literal's block inside a plain class's method" => [
      "class Controller\n  def actions = %w[a b].map { |a| a == \"x\" ? :refine : :show }\nend\n", %i[data], {}
    ],
    "a refine call in a literal's block and a define_method block of a plain class" => [
      "class Query\n  def refine(n) = yield(n)\n  def all = [1, 2].map { |n| refine(n) { |q| q * 10 } }\n  " \
      "define_method(:one) { refine(1) { |q| q + 1 } }\nend\n",
      %i[dsl dsl], {}
    ],
    "a refine in an implicit instance_eval block" => [
      "module M\n  instance_eval { refine(String) { def shout = 1 } }\nend\n",
      %i[recorded], { "M::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    # R3-S3: an eval's constant receiver is charged under every name its spelling can denote, as another file may
    # declare the inner one (Ruby 4.0.5 refines for `L::M` where another file declares it: the integration example
    # "declines under a module an eval block's constant receiver names in another file").
    "a block-form module_eval charges its receiver" => [
      "module L\n  M.module_eval { refine(String) { def shout = 1 } }\nend\n",
      %i[recorded], { "L::String" => { shout: ["L::M", "M"] }, "String" => { shout: ["L::M", "M"] } }
    ],
    # Every other charge in such a block takes every name too. With `module L; module M; end; end` loaded, Ruby 4.0.5
    # prints `:dsm` (after `L::M.setup`), `:each_target`, `:send` and `:alias` for these under `using L::M`.
    "a refine in a define_singleton_method block of an eval block on a constant" => [
      "module L\n  M.module_eval { define_singleton_method(:setup) { refine(String) { def center(a, b, c) = 1 } } }\n" \
      "end\n",
      %i[targets_wildcard], { any => { any => ["L::M", "M"] } }
    ],
    "a refine with a computed target in an eval block on a constant" => [
      "module L\n  M.module_eval { [String].each { |k| refine(k) { def ljust(a, b, c) = 1 } } }\nend\n",
      %i[class_unknown], { any => { ljust: ["L::M", "M"] } }
    ],
    "send(:refine, …) in an eval block on a constant" => [
      "module L\n  M.module_eval { send(:refine, String) { def rjust(a, b, c) = 1 } }\nend\n",
      %i[literal], { any => { any => ["L::M", "M"] } }
    ],
    "alias my_refine refine in class << self of an eval block on a constant" => [
      "module L\n  M.module_eval do\n    class << self\n      alias my_refine refine\n    end\n  end\nend\n",
      %i[literal], { any => { any => ["L::M", "M"] } }
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
    # R2-S1: a heredoc's body follows its line, so it can end after an endless `def` (or a `def … end` on one line)
    # that opens it. Ruby 4.0.5 prints `:heredoc_def` and `:heredoc_one_line` for these, each refining for `Ext`.
    "a refine heredoc an endless def evals" => [
      "module Ext\n  def self.install = module_eval(<<~RUBY)\n    refine(String) { def center(a, b, c) = 1 }\n  " \
      "RUBY\nend\n",
      %i[literal], { any => { any => ["Ext"] } }
    ],
    "a refine heredoc a one-line def evals" => [
      "module Ext\n  def self.install; module_eval(<<~RUBY); end\n    refine(String) { def center(a, b, c) = 1 }\n  " \
      "RUBY\nend\n",
      %i[literal], { any => { any => ["Ext"] } }
    ],
    # A literal whose bytes are not valid in its encoding is read as bytes, not raised on.
    "an eval string whose bytes are not valid in its encoding" => [
      "module M\n  module_eval(\"\\xff refine(String) { def shout = 1 }\")\nend\n",
      %i[literal], { any => { any => ["M"] } }
    ],
    # R3-S1: binary `__END__` data is not valid in the file's encoding; the text is scanned as bytes, not raised on.
    "a refine above binary __END__ data" => [
      "module M\n  refine(String) { def shout = 1 }\nend\n__END__\n\x89PNG\xff\xfe refine\n",
      %i[recorded], { "M::String" => { shout: ["M"] }, "String" => { shout: ["M"] } }
    ],
    "no refine above binary __END__ data" => [
      "class Helper\n  def self.go(a) = a\nend\n__END__\n\x89PNG\xff\xfe\n", [], {}
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
    # The walk names a bare `Module.new` block by its position; a `using` of the call is the unknown marker.
    "a bare Module.new block" => [
      "using Module.new { refine(String) { def whisper = 1 } }\n" \
      "Module.new do\n  refine(String) { def other = 1 }\nend\n",
      %i[recorded recorded], { "String" => { whisper: ["#<Module:1:6>"], other: ["#<Module:2:0>"] } }
    ],
    # M3, Ruby 4.0.5: in a plain class's method `self` is an instance of the class (or the class), which has no
    # `Module#refine`: `class C; def self.setup = refine(String) { … }; end; C.setup` raises `NoMethodError`, a
    # `Query#refine` the class defines runs its own block, and a `:refine` Symbol there is data. A `Module`
    # subclass's instance method runs on a module: `class MyMod < Module; def setup = refine(String) { … }; end`
    # refines for the `MyMod` instance that calls it.
    "a :refine Symbol in a plain class's method" => [
      "class Controller\n  def action_name = :refine\nend\n", %i[data], {}
    ],
    # R3-M1: a parameter's default runs in the method's body, a superclass expression where `class` is. Ruby 4.0.5
    # prints `:refine` for `Search.build`'s `@mode`, `M::Base` for `M::C.superclass` and `:refine` for `M.dflt`.
    "a :refine default in a plain class's method parameters" => [
      "class Search\n  def initialize(mode = :refine) = @mode = mode\n  " \
      "def self.build(kind = :refine) = new(kind)\nend\n",
      %i[data data], {}
    ],
    "a :refine literal in a superclass expression and a module's method parameter" => [
      "module M\n  class C < Base.with(:refine)\n  end\n  def self.dflt(m = :refine) = m\nend\n",
      %i[literal literal], { any => { any => ["M"] } }
    ],
    "a refine in a plain class's methods" => [
      "class Query\n  def refine(extra) = yield(extra)\n  def narrowed = refine(1) { |q| q }\n  " \
      "def self.setup = refine(String) { def x = 1 }\nend\n",
      %i[dsl dsl], {}
    ],
    # #1749: a `def self.x` (or a `def` in `instance_eval`) written in an eval block on a constant is the receiver's own
    # singleton method. Ruby 4.0.5 prints `1` and `2` for `Ext.setup; Ext.setup2; using Ext` after the first shape, and
    # for `M.setup; M.setup2; using M` after the second (the block runs on the top-level `M`, as `L::M` does not exist).
    # The eval's file need not declare the module, and the lookup of a refine body consults the files that do, so the
    # record that the method creates the names could go unseen: they keep the targets-wildcard, charged to the receiver
    # (a constant that several names denote, `M` in `module L`, is charged to each).
    "a refine in a singleton method defined in an eval block on a constant" => [
      <<~RUBY, %i[targets_wildcard targets_wildcard], { any => { any => ["Ext"] } }
        Ext.module_eval do
          def self.setup = refine(String) { def yy = 1 }
        end
        Ext.instance_eval do
          def setup2 = refine(Symbol) { def ww = 1 }
        end
      RUBY
    ],
    "a refine in a singleton method defined in a class << self body of an eval block on a constant" => [
      <<~RUBY, %i[targets_wildcard], { any => { any => ["Ext"] } }
        Ext.module_eval do
          class << self
            def setup = refine(String) { def yy = 1 }
          end
        end
      RUBY
    ],
    "a refine in a singleton method defined in an eval block on self in an eval block on a constant" => [
      <<~RUBY, %i[targets_wildcard], { any => { any => ["Ext"] } }
        Ext.module_eval do
          module_eval do
            def self.setup = refine(String) { def yy = 1 }
          end
        end
      RUBY
    ],
    "a refine in a singleton method defined in an eval block on self in a module" => [
      <<~RUBY, %i[recorded], { "M::String" => { yy: ["M"] }, "String" => { yy: ["M"] } }
        module M
          module_eval do
            def self.setup = refine(String) { def yy = 1 }
          end
        end
      RUBY
    ],
    "a refine in a singleton method defined in an eval block on a constant several names denote" => [
      <<~RUBY, %i[targets_wildcard targets_wildcard], { any => { any => ["L::M", "M"] } }
        module L
          M.module_eval do
            def self.setup = refine(String) { def yy = 1 }
          end
          M.instance_eval do
            def setup2 = refine(String) { def ww = 1 }
          end
        end
      RUBY
    ],
    # An instance method of a refine body runs on an instance of the refined class, whatever the eval around names.
    "a refine in an instance def in a refine body of an instance_eval block on a constant" => [
      <<~RUBY, %i[recorded targets_wildcard], { "String" => { shout: ["Ext"] }, any => { any => [any] } }
        Ext.instance_eval do
          refine(String) { def shout = refine(Integer) { def twice = 1 } }
        end
      RUBY
    ],
    "a refine in an instance def in a refine body of an instance_eval block on a constant several names denote" => [
      <<~RUBY, %i[recorded targets_wildcard],
        module L
          M.instance_eval do
            refine(String) { def shout = refine(Integer) { def twice = 1 } }
          end
        end
      RUBY
      { "L::String" => { shout: ["L::M", "M"] }, "String" => { shout: ["L::M", "M"] }, any => { any => [any] } }
    ],
    "a refine in a Module subclass's instance method" => [
      "class MyMod < Module\n  def setup = refine(String) { def shout = 1 }\nend\n",
      %i[targets_wildcard], { any => { any => [any] } }
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

  # Each fixture's outcomes and table; the census invariant (the nodes counted independently are exactly the nodes the
  # walk accounted for, each once); and R2's parity: the module-body walk, the method-body census scan and the
  # in-effect walk charge every `refine`-shaped node where one function (`RefineCensus`'s contexts, worked out by the
  # in-effect walk) says it runs, so they agree on the module charged and on activation against DSL.
  fixtures.each do |name, (source, outcomes, table)|
    it "accounts for #{name}" do
      recorded, accounted = census(source)
      offsets = accounted.map(&:first)
      root = Prism.parse(source).value
      query = Rigor::Inference::InEffectRefinements.new(root)
      nodes = refine_shaped_nodes(root).to_h { |node| [node.location.start_offset, node] }

      expect(accounted.map { |entry| entry[1] }).to eq(outcomes)
      expect(recorded).to eq(table)
      expect(offsets.sort).to eq(refine_shaped_offsets(root).sort)
      expect(offsets.uniq.size).to eq(offsets.size)
      problems = accounted.filter_map do |offset, outcome, charged|
        parity_problem(query, nodes.fetch(offset), outcome, charged)
      end
      expect(problems).to eq([])
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
      "a call in a condition" => "def x = 1 if respond_to?(:y)",
      # Ruby 4.0.5 raises `EncodingError` for a name no Symbol holds.
      "a define_method name no Symbol holds" => 'define_method("\\xff") { 1 }',
      "an attr_reader name no Symbol holds" => 'attr_reader "\\xff"'
    }.each do |name, body|
      it "makes the names incomplete for #{name}" do
        expect(rows(body)).to include(wildcard => ["M"])
      end
    end
  end
end
