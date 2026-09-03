# frozen_string_literal: true

module Rigor
  module Source
    # Flattens a Prism constant-reference node (`ConstantReadNode` / `ConstantPathNode`) to its
    # source-qualified `"A::B::C"` string.
    #
    # Two nil policies for the one edge case that distinguishes the call sites — a constant path rooted in a
    # *dynamic* base (`expr::Bar`, where the left side is a runtime expression rather than a constant):
    #
    # * {.qualified_name} / {.render} are LENIENT — they drop the dynamic segment and render the trailing
    #   constant names (`expr::Bar` => "Bar"). The scope indexer and statement evaluator feed only genuine
    #   class/module path nodes and want a best-effort name.
    # * {.qualified_name_or_nil} is STRICT — a dynamic base anywhere in the chain yields `nil`, so a caller
    #   that statically names constants can treat the path as opaque rather than guessing.
    #
    # A leading `::` (absolute root, `::Foo`) renders as `"Foo"` under both policies: the discovered-constant
    # tables are keyed by un-rooted names, so a rendered `"::Foo"` would miss every one of them. The root
    # marker is therefore carried OUT OF BAND by {.rooted?}, which a caller performing Ruby's lexical constant
    # lookup MUST consult — `::Foo` names the top-level `Foo` and never a lexically nearer shadow
    # ([#614](https://github.com/rigortype/rigor/issues/614)). A node that is neither a `ConstantReadNode`
    # nor a `ConstantPathNode` yields `nil` under both policies.
    #
    # A `class` / `module` HEADER is a constant path too, and it has to consult the same marker — which is why
    # {.declaration_prefix} and {.pushed_nesting} live here rather than in each of the two dozen walks that
    # used to append the rendered name to their own prefix. `::` re-anchors a header at the top level exactly
    # as it re-anchors a reference; reading only the rendered name filed `class ::Foo` inside `module MyApp`
    # under `MyApp::Foo` ([#708](https://github.com/rigortype/rigor/issues/708)).
    module ConstantPath
      module_function

      # Lenient dispatch over a constant-reference node.
      def qualified_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then render(node)
        end
      end

      # Lenient render of a `ConstantPathNode`; never nil for a path node.
      def render(node)
        prefix =
          case node.parent
          when Prism::ConstantReadNode then "#{node.parent.name}::"
          when Prism::ConstantPathNode then "#{render(node.parent)}::"
          else ""
          end
        "#{prefix}#{node.name}"
      end

      # Strict dispatch: a dynamic base anywhere in the path yields nil.
      def qualified_name_or_nil(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent
          return node.name.to_s if parent.nil?

          parent_name = qualified_name_or_nil(parent)
          return nil if parent_name.nil?

          "#{parent_name}::#{node.name}"
        end
      end

      # True when the reference is written with a leading `::` — `::Foo`, `::Foo::Bar`. Prism spells the
      # root as a `ConstantPathNode` with a nil `parent`, so the answer lives at the LEFTMOST segment of the
      # chain and the walk has to reach it: `::Foo::Bar` is a path node whose parent is itself a path node.
      # A `ConstantReadNode` is a bare name and is never rooted; a dynamic base (`expr::Bar`) is not a root
      # either, so the recursion stops at any non-constant parent.
      def rooted?(node)
        return false unless node.is_a?(Prism::ConstantPathNode)

        parent = node.parent
        return true if parent.nil?

        rooted?(parent)
      end

      # The qualified prefix a `class` / `module` header contributes to the body it opens, given the prefix of
      # the body the header is WRITTEN in. `class Bar` inside `module Outer` is `Outer::Bar`; the compact
      # `class Outer::Bar` written at the top level is the same name through one keyword instead of two.
      #
      # A ROOTED header RESETS the prefix. `class ::Rooted::Bar` names `Rooted::Bar` wherever it is written —
      # Ruby's `::` re-anchors the header at the top level exactly as it does a reference — so the enclosing
      # prefix is DROPPED rather than kept. Keeping it filed the class under `Outer::Rooted::Bar`, a name no
      # caller writes, and the single-segment `class ::Foo` inside `module MyApp` became `MyApp::Foo`: not
      # merely mis-keyed but undiscoverable, so a call on `Foo` typed opaque and reported nothing at all
      # ([#708](https://github.com/rigortype/rigor/issues/708), [#638](https://github.com/rigortype/rigor/issues/638)).
      #
      # nil when the header names no constant — the same refusal {.qualified_name} makes, propagated so a
      # caller keeps its own prefix rather than qualifying under a name it could not render.
      def declaration_prefix(outer_prefix, constant_path)
        name = qualified_name(constant_path)
        return nil if name.nil?

        rooted?(constant_path) ? [name] : outer_prefix + [name]
      end

      # Ruby's `Module.nesting` inside the body a `class` / `module` header opens, given the nesting of the
      # body the header is written in. ONE entry per declaration keyword, qualified against the entry already
      # on top, so a compact `class A::B` contributes the single `"A::B"` where `module A; class B` contributes
      # two — the whole difference between the two spellings, and unrecoverable from the `"A::B"` they share
      # afterwards ([#652](https://github.com/rigortype/rigor/issues/652)). This is the ONLY thing that pushes
      # an entry: a `def`, a block, and a `class << expr` body each inherit the chain unchanged, because none
      # of them pushes a cref in Ruby.
      #
      # A ROOTED header pushes its name UNQUALIFIED and leaves the enclosing entries beneath it, which is the
      # one place this differs from {.declaration_prefix}: Ruby's nesting inside `class ::Rooted::Bar` written
      # in `module Outer` is `[Rooted::Bar, Outer]`, so the class's own name resets while `Outer` stays on the
      # ladder as a live rung ([#708](https://github.com/rigortype/rigor/issues/708)).
      #
      # The header is rendered by the LENIENT {.qualified_name}, which is total over every header Ruby parses —
      # `class` and `module` require a constant path, so the only dynamic base the grammar admits is `self`, and
      # `class self::Thing` inside `module Outer` renders `"Thing"` and records `["Outer::Thing", "Outer"]`,
      # which is what Ruby's nesting is there. So there is no unnameable-header case to refuse, and the `nil`
      # guards below are reachable only for a non-constant node (which a `ClassNode` / `ModuleNode` header
      # never is) and for the nil chain a caller may thread in.
      #
      # Both nesting walks call THIS function — `Inference::StatementEvaluator`'s declaration walk and
      # `Inference::ScopeIndexer`'s def-node walk — so a callee re-walk answers what the body's own walk
      # answers by construction rather than by two mirrored implementations staying in step.
      def pushed_nesting(nesting, constant_path)
        return nil if nesting.nil?

        name = qualified_name(constant_path)
        return nil if name.nil?

        outer = rooted?(constant_path) ? nil : nesting.first
        [outer ? "#{outer}::#{name}" : name, *nesting].freeze
      end
    end
  end
end
