# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::ReturnType.diagnostic} on a parsed snippet and its scope index, with no runner: the
# snippet's own `def`s give the class they sit in, and a signature file gives the RBS return they are compared with.
# `override_and_return_type_spec.rb` and `spec/integration/refinement_using_scope_spec.rb` pin the rule through the
# whole run.
#
# Mutation-proved: each guard line (a `return` / `next` modifier) of `diagnostic`, `return_type_mismatch_diagnostic` and
# the helpers it calls was blanked in turn and an example here failed, except these, which no input here distinguishes
# (one line on what was tried each):
#
# - `return nil if def_node.body.nil?` and `return nil if last_expr.nil?`: an empty body reaches the same nil last
#   expression, so each is backed by the other.
# - `return nil if inner_scope.nil?` and `return nil if scope.nil?` in `declared_return_type`: every `def` of an
#   indexed snippet has a scope.
# - `return nil if OverrideSupport.dynamic_top?(inferred)`: a `Dynamic` body (`def ret_int(x) = x`) is declined by the
#   `compare_return` line after it, whose `accepts` is `maybe`, not `no`; `top?` is never defined (#3303).
# - the `refinement_def?` test of `diagnostic` (replacing `... ? nil : diagnostic` with `diagnostic` fails no example
#   here, none in `spec/integration/refinement_using_scope_spec.rb`, and changes no CLI output on a `refine` body): a
#   `refine String do def upcase = nil end` body is typed with no `self` class in a snippet indexed against an empty
#   scope, and the rule answers nil for such a `def` before the test is asked, so no spec pins it. See the issue
#   filed from #3308's review.
RSpec.describe Rigor::Analysis::CheckRules::ReturnType do
  def defs_in(node, found = [])
    found << node if node.is_a?(Prism::DefNode)
    node.compact_child_nodes.each { |child| defs_in(child, found) }
    found
  end

  def indexed(program, sig)
    environment = Rigor::Environment.for_project(signature_paths: [RunnerHelpers.materialise_sig("demo.rbs" => sig)])
    Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty(environment: environment))
  end

  # `[line, message]` for each `def` of `source` the rule reports against `sig`, with the file's lexical sites.
  def fired(source, sig = signatures)
    program = Prism.parse(source).value
    scope_index = indexed(program, sig)
    refinements = Rigor::Analysis::CheckRules.stamped_refinements(scope_index, program)
    sites = Rigor::Analysis::CheckRules::LexicalMethodSites.new(program, refinements)
    defs_in(program).filter_map do |def_node|
      row = described_class.diagnostic("mem.rb", def_node, scope_index, sites)
      [def_node.location.start_line, row.message] if row
    end
  end

  def msg(line, name, declared, inferred)
    [line, "return-type mismatch on `#{name}': declared #{declared}, inferred #{inferred}"]
  end

  def signatures
    <<~RBS
      class Foo
        def ret_int: () -> Integer
        def ret_top: () -> top
        def ret_untyped: () -> untyped
        def ret_void: () -> void
        def ret_arr: () -> Array[Integer]
        def ret_nilable: () -> Integer?
        def ret_over: () -> Integer
                    | () -> String
        def ret_bool: () -> bool
        %a{rigor:v1:return: non-empty-string}
        def ret_name: () -> String
        def self.build: () -> Integer
        def self.other: () -> Integer
      end
      class Base
        def val: () -> Integer
      end
      class Sub < Base
      end
      module Mod
        def mval: () -> Integer
      end
      class GOut
        def pick: (bool) -> StringIO
      end
    RBS
  end

  def in_foo(body, indent = 2)
    "class Foo\n#{body.lines.map { |l| "#{' ' * indent}#{l}" }.join}end\n"
  end

  describe "an instance method" do
    it "reports a body whose last expression the declared return rejects, at the method name" do
      expect(fired(in_foo(%(def ret_int = "a"\n)))).to eq([msg(2, "ret_int", "Integer", '"a"')])
    end

    it "carries the rule id, the error severity, the method name, the path and the name's position" do
      source = in_foo(%(def ret_int = "a"\n))
      program = Prism.parse(source).value
      row = described_class.diagnostic("mem.rb", defs_in(program).first, indexed(program, signatures), nil)

      expect([row.rule, row.severity, row.method_name, row.path, row.line, row.column]).to eq(
        [Rigor::Analysis::CheckRules::RULE_RETURN_TYPE, :error, "ret_int", "mem.rb", 2, 7]
      )
    end

    it "is silent for an accepted body" do
      expect(fired(in_foo("def ret_int = 1\n"))).to eq([])
    end

    it "reports a union body with the whole union as the inferred type" do
      expect(fired(in_foo(%(def ret_int(c) = c ? 1 : "a"\n)))).to eq([msg(2, "ret_int", "Integer", '"a" | 1')])
    end

    it "reports a generic, a nilable and a bool return the body does not satisfy" do
      expect([fired(in_foo(%(def ret_arr = ["a"]\n))), fired(in_foo(%(def ret_nilable = "a"\n))),
              fired(in_foo("def ret_bool = 1\n"))]).to eq(
                [[msg(2, "ret_arr", "Array[Integer]", '["a"]')], [msg(2, "ret_nilable", "Integer?", '"a"')],
                 [msg(2, "ret_bool", "bool", "1")]]
              )
    end

    it "accepts the union of the overloads' returns" do
      expect([fired(in_foo(%(def ret_over = "a"\n))), fired(in_foo("def ret_over = :a\n"))]).to eq(
        [[], [msg(2, "ret_over", "Integer | String", ":a")]]
      )
    end

    it "is silent for a `top`, an `untyped` and a `void` return, whatever the body is" do
      expect([fired(in_foo("def ret_top = 1\n")), fired(in_foo("def ret_untyped = 1\n")),
              fired(in_foo("def ret_void = 1\n"))]).to eq([[], [], []])
    end

    it "judges the body by a `rigor:v1:return` refinement, not by the RBS class" do
      expect([fired(in_foo(%(def ret_name = ""\n))), fired(in_foo(%(def ret_name = "a"\n)))]).to eq(
        [[msg(2, "ret_name", "non-empty-string", '""')], []]
      )
    end

    it "takes the last expression of a multi-statement body" do
      expect(fired(in_foo(%(def ret_int\n  1\n  "a"\nend\n)))).to eq([msg(2, "ret_int", "Integer", '"a"')])
    end

    it "takes the last expression of a `begin` body, and no value from a `rescue` clause" do
      expect(fired(in_foo(%(def ret_int\n  begin\n    1\n    "a"\n  end\nend\n)))).to eq(
        [msg(2, "ret_int", "Integer", '"a"')]
      )
    end

    it "is silent for an empty body, a `Dynamic` body and a method no signature declares" do
      expect([fired(in_foo("def ret_int\nend\n")), fired(in_foo("def ret_int(x) = x\n")),
              fired(in_foo("def nothing = 1\n"))]).to eq([[], [], []])
    end

    it "is silent for a top-level method, which names no class" do
      expect(fired(%(def ret_int = "a"\n))).to eq([])
    end

    it "is silent for a method whose only declaration is inherited, and reports one the class declares" do
      expect([fired("class Sub\n  def val = \"a\"\nend\n"), fired("class Base\n  def val = \"a\"\nend\n")]).to eq(
        [[], [msg(2, "val", "Integer", '"a"')]]
      )
    end

    it "reports a module's method against the module's declaration" do
      expect(fired(%(module Mod\n  def mval = "a"\nend\n))).to eq([msg(2, "mval", "Integer", '"a"')])
    end

    it "reports a method defined in a block of the class body, and the later of two defs of one name" do
      expect([fired(in_foo(%([1].each do\n  def ret_int = "a"\nend\n))).map(&:first),
              fired(in_foo(%(def ret_int = 1\ndef ret_int = "a"\n))).map(&:first)]).to eq([[3], [3]])
    end

    it "reports a class written as `class ::Foo`, and not one nested in a module that has no declaration" do
      expect([fired(%(class ::Foo\n  def ret_int = "a"\nend\n)).size,
              fired(%(module M\n  class Foo\n    def ret_int = "a"\n  end\nend\n))]).to eq([1, []])
    end

    it "withholds the declared-only members of a joined builtin global" do
      source = "$stdout = StringIO.new\nclass GOut\n  def pick(c) = c ? $stdout : StringIO.new\nend\n"

      expect(fired(source)).to eq([])
    end

    it "judges a body ending on a builtin global by the file's writes to it" do
      bare = in_foo("def ret_int = $VERBOSE\n")
      written = "$VERBOSE = true\n#{bare}"
      joined = "$VERBOSE = true\n#{in_foo("def ret_int(c) = c ? $VERBOSE : 1\n")}"

      expect([fired(bare), fired(written), fired(joined)]).to eq(
        [[], [msg(3, "ret_int", "Integer", "true")], [msg(3, "ret_int", "Integer", "bool | 1")]]
      )
    end
  end

  describe "a singleton method" do
    it "reports `def self.x`, `def Foo.x` in Foo's body and `def (self).x`" do
      expect([fired(in_foo(%(def self.build = "a"\n))), fired(in_foo(%(def Foo.build = "a"\n))),
              fired(in_foo(%(def (self).build = "a"\n)))]).to eq([[msg(2, "build", "Integer", '"a"')]] * 3)
    end

    it "reports a `def` of a `class << self` body against the singleton signature" do
      expect(fired(%(class Foo\n  class << self\n    def build = "a"\n  end\nend\n)).map(&:first)).to eq([3])
    end

    it "is silent for a def on another object" do
      expect(fired(in_foo(%(def String.build = "a"\n)))).to eq([])
    end

    it "is silent for a module's `def self.x`, which the module's instance signature does not describe" do
      expect(fired(%(module Mod\n  def self.mval = "a"\nend\n))).to eq([])
    end

    it "is silent for a singleton def a later def of the name replaced, and reports the later one" do
      expect(fired(in_foo(%(def self.build = "a"\ndef self.build = 1\n)))).to eq([])
      expect(fired(in_foo(%(def self.build = 1\ndef self.build = "a"\n))).map(&:first)).to eq([3])
    end

    it "reports a def under `instance_eval` in the class body as a singleton def" do
      expect(fired(in_foo(%(instance_eval do\n  def build = "a"\nend\n))).map(&:first)).to eq([3])
    end

    it "is silent for a def in a refine body" do
      source = %(module R\n  refine String do\n    def upcase = nil\n  end\nend\n)

      expect(fired(source)).to eq([])
      expect(fired(%(class String\n  def upcase = nil\nend\n)).size).to eq(1)
    end
  end
end
