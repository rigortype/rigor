# frozen_string_literal: true

require "prism"

require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # Walks a parse tree and collects every Hash-literal entry whose LITERAL key repeats an earlier
      # literal key in the same literal. Ruby's runtime keeps the LAST entry silently (the interpreter
      # itself only warns under `-w`), so the earlier value is dead — almost always a copy-paste or merge
      # leftover. Modeled on PHPStan's `DuplicateKeysInLiteralArraysRule`.
      #
      # The collector is the read-side companion to the `flow.duplicate-hash-key` rule. The envelope is
      # purely syntactic and deliberately narrow so it cannot fire on working code:
      #
      # - Only keys whose VALUE is pinned at parse time participate: symbols (including the `key:`
      #   shorthand and the `:key =>` hashrocket spelling of the same symbol), plain non-interpolated
      #   strings, integers, floats, and the `true` / `false` / `nil` literals. Any other key form —
      #   interpolated strings/symbols, constants, method calls, locals — is never compared and never
      #   fires.
      # - Key spaces are tagged by literal kind, matching `Hash`'s `eql?`-based lookup: `:a` and `"a"`
      #   are different keys, and `1` and `1.0` are different keys (`1.eql?(1.0)` is false), so Integer
      #   and Float literals are never cross-compared.
      # - A `**splat` element is itself never a key, and it does NOT rescue a literal duplicate around
      #   it: in `{ a: 1, **h, a: 2 }` the second `a:` overwrites whatever the earlier entries (literal
      #   or splatted) contributed, so the pair still collides and still fires.
      # - Both `Prism::HashNode` (braced literals) and `Prism::KeywordHashNode` (bare keyword arguments,
      #   `m(a: 1, a: 2)` — Prism parses these with only a `-w`-level warning, same as braced literals)
      #   are scanned. Each literal is scanned independently; nested Hash literals are their own scope.
      class DuplicateHashKeyCollector
        # ADR-53 Track B — the node classes the shared {RuleWalk} dispatches to this collector. Prism node
        # classes are leaves, so class-equality dispatch matches the legacy walk's `is_a?` gate. The
        # collector needs no context gate: it is purely syntactic and fires wherever the full DFS reaches
        # a Hash literal, loops and blocks included.
        NODE_CLASSES = [Prism::HashNode, Prism::KeywordHashNode].freeze

        # Returns `Array<{hash_node:, key_node:, first_key_node:, key_label:}>` — one entry per LATER
        # occurrence of a repeated literal key (`key_node` is the repeat the diagnostic points at;
        # `first_key_node` is the earliest occurrence its message references). Empty when the tree has no
        # qualifying duplicates.
        def initialize(scope_index)
          @scope_index = scope_index
          @results = []
        end

        # Legacy single-collector walk — kept as the oracle the ADR-53 Track B equivalence harness
        # compares {RuleWalk} against.
        def collect(root)
          walk_for_hash_nodes(root)
          @results.freeze
        end

        # {RuleWalk} entry point: the legacy walk's per-literal logic, invoked at every Hash literal under
        # the shared traversal contract. The `context` is unused — this collector processes all literals.
        def visit(hash_node, _context = nil)
          collect_duplicate_keys(hash_node)
        end

        # The accumulated result, frozen the same way `#collect` returns it — used by {RuleWalk}-driven
        # callers after the walk completes.
        def results
          @results.freeze
        end

        private

        def walk_for_hash_nodes(node)
          return unless node.is_a?(Prism::Node)

          collect_duplicate_keys(node) if node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
          node.rigor_each_child { |child| walk_for_hash_nodes(child) }
        end

        def collect_duplicate_keys(hash_node)
          seen = {}
          hash_node.elements.each do |element|
            # `**splat` elements (AssocSplatNode) contribute no literal key; they are skipped WITHOUT
            # resetting `seen` — a splat between two identical literal keys does not rescue the collision.
            next unless element.is_a?(Prism::AssocNode)

            key = literal_key(element.key)
            next if key.nil?

            first = seen[key]
            if first
              @results << {
                hash_node: hash_node,
                key_node: element.key,
                first_key_node: first,
                key_label: key_label(element.key)
              }
            else
              seen[key] = element.key
            end
          end
        end

        # Maps a key node to a comparable `[kind, value]` tag, or nil for any non-value-pinned key form.
        # The kind tag keeps the literal spaces separate (`:a` ≠ `"a"`, `1` ≠ `1.0`); within a kind the
        # parsed Ruby value is compared under Hash's own `eql?`/`hash` semantics, exactly reproducing the
        # runtime collision.
        def literal_key(key_node)
          case key_node
          when Prism::SymbolNode then [:symbol, key_node.unescaped]
          when Prism::StringNode then [:string, key_node.unescaped]
          when Prism::IntegerNode then [:integer, key_node.value]
          when Prism::FloatNode then [:float, key_node.value]
          when Prism::TrueNode then [:true_literal]
          when Prism::FalseNode then [:false_literal]
          when Prism::NilNode then [:nil_literal]
          end
        end

        # Renders the key for the diagnostic message in its canonical Ruby spelling, so the `a:` shorthand
        # and `:a =>` hashrocket occurrences of one symbol read as the same key.
        def key_label(key_node)
          case key_node
          when Prism::SymbolNode then ":#{key_node.unescaped}"
          when Prism::StringNode then key_node.unescaped.inspect
          else key_node.slice
          end
        end
      end
    end
  end
end
