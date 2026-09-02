# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class ShouldaMatchers < Rigor::Plugin::Base
      # Walks every `RSpec.describe <ModelConst> do ... end` / `describe <ModelConst> do ... end` block and
      # validates the shoulda-matchers calls inside its body (any depth of nested `describe` / `context`)
      # against the `:model_index` published by `rigor-activerecord`.
      #
      # The "anchor" for cross-checking is the OUTERMOST describe block whose argument is a constant —
      # that constant names the model being specced. Nested `describe ".some_method"` (String / Symbol
      # args) does NOT change the anchor.
      #
      # ## Recognised matcher calls (v0.1.0)
      #
      # ### Column / db matchers
      #
      #   validate_presence_of(:col)
      #   validate_uniqueness_of(:col)
      #   validate_length_of(:col)
      #   validate_numericality_of(:col)
      #   validate_acceptance_of(:col)
      #   validate_inclusion_of(:col)
      #   validate_exclusion_of(:col)
      #   validate_absence_of(:col)
      #   validate_format_of(:col)
      #   validate_confirmation_of(:col)
      #   have_db_column(:col)
      #   have_db_index(:col)
      #
      # All look up `:col` against the model's `columns:` (the published `:model_index` fact's flat
      # `Array<String>` per model — see `Analyzer#column_names`). Unknown columns fire `unknown-column`.
      #
      # ### Association matchers
      #
      #   belong_to(:assoc)           ← expects :singular
      #   have_one(:assoc)            ← expects :singular
      #   have_many(:assoc)           ← expects :collection
      #   have_and_belong_to_many(:assoc) ← expects :collection
      #
      # Unknown associations fire `unknown-association`. Known associations with mismatched kind (`should
      # belong_to(:posts)` where `:posts` is `has_many`) fire `association-kind-mismatch`.
      module Analyzer
        # One matcher violation (always `:warning`). Carries no path/location — the caller (the
        # `node_rule` block) positions it at the matcher name (`message_loc`) via `Plugin::Base#diagnostic`.
        Violation = Struct.new(:rule, :message, keyword_init: true)

        # `(matcher_name) => (:column | :association_singular | :association_collection)` — the
        # validation lane each matcher routes to.
        MATCHER_TABLE = {
          # Column matchers — validate the named column exists on the model.
          validate_presence_of: :column,
          validate_uniqueness_of: :column,
          validate_length_of: :column,
          validate_numericality_of: :column,
          validate_acceptance_of: :column,
          validate_inclusion_of: :column,
          validate_exclusion_of: :column,
          validate_absence_of: :column,
          validate_format_of: :column,
          validate_confirmation_of: :column,
          have_db_column: :column,
          have_db_index: :column,
          # Association matchers — validate the association exists AND its kind matches the matcher.
          belong_to: :association_singular,
          have_one: :association_singular,
          have_many: :association_collection,
          have_and_belong_to_many: :association_collection
        }.freeze

        module_function

        # @param path [String]
        # @param root [Prism::Node]
        # @param model_index [Hash{String => Hash}, nil] the `:model_index` fact value — the flat
        #   `class_name => { table:, columns:, associations:, ... }` Hash `rigor-activerecord` publishes
        #   (ADR-9's "the value is data, not objects" contract; see `Activerecord#index_to_published_hash`).
        #   When nil the analyzer falls silent.
        # @return [Array<Diagnostic>]
        # The matcher violations for a single call node (0..1), or `[]` when it is not a shoulda matcher,
        # sits outside any `describe <ModelConst>` block, or the model is unknown. ADR-37: the engine owns
        # the walk; the model anchor comes from the node-rule `NodeContext` ancestors (the innermost
        # enclosing `describe`-with-constant — nested const describes override, `describe ".method"`
        # string blocks inherit), exactly as the former recursive anchor propagation did.
        #
        # @param matcher_call [Prism::Node]
        # @param ancestors [Array<Prism::Node>]
        # @param model_index [Hash{String => Hash}, nil]
        # @return [Array<Violation>]
        def violations_for(matcher_call:, ancestors:, model_index:)
          return [] if model_index.nil?
          return [] unless matcher_invocation?(matcher_call)

          anchor = anchor_for(ancestors)
          return [] if anchor.nil?

          # Keyed Hash lookup — NOT `ModelIndex#find`. The published fact is a plain Hash (`class_name =>
          # entry Hash`), never the `ModelIndex` object `rigor-activerecord` builds internally (issue #573:
          # `Hash#find(anchor)` with no block returns an Enumerator, not the entry).
          entry = model_index[anchor]
          return [] if entry.nil?

          violation = diagnostic_for(matcher_call, anchor, entry)
          violation ? [violation] : []
        end

        # The model anchor in effect at a node: the constant named by the innermost enclosing `describe
        # <Const> do … end`, or nil.
        def anchor_for(ancestors)
          describe = ancestors.rfind { |n| describe_with_constant?(n) }
          describe && describe_const_name(describe)
        end

        # A direct matcher invocation is a `CallNode` whose `name` is in `MATCHER_TABLE` and whose first
        # argument is a `SymbolNode`. The chain shape (`should`, `expect(...).to`, `is_expected.to`) is
        # irrelevant — we always recurse to the inner matcher, so a diagnostic fires on the matcher
        # regardless of the surrounding chain.
        def matcher_invocation?(node)
          node.is_a?(Prism::CallNode) && MATCHER_TABLE.key?(node.name) && symbol_first_arg?(node)
        end

        def symbol_first_arg?(call_node)
          args = call_node.arguments&.arguments || []
          !args.empty? && args.first.is_a?(Prism::SymbolNode)
        end

        # Detects `RSpec.describe(Const) do ... end` and `describe(Const) do ... end`. Either form opens a
        # scope whose anchor is `Const`. The receiver shape (RSpec vs nil) is allowed in both cases.
        def describe_with_constant?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless node.name == :describe
          return false unless node.block.is_a?(Prism::BlockNode)

          args = node.arguments&.arguments || []
          first = args.first
          first.is_a?(Prism::ConstantReadNode) || first.is_a?(Prism::ConstantPathNode)
        end

        def describe_const_name(node)
          arg = node.arguments.arguments.first
          render_constant_path(arg)
        end

        # The anchor is the constant path WITHOUT a leading `::` — `describe ::User` anchors on `"User"`,
        # the same spelling `describe User` produces — because the `:model_index` fact is keyed by the
        # de-rooted class name however the model was declared (#583; `Activerecord#index_to_published_hash`).
        def render_constant_path(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil then parts.join("::")
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end

        # --- diagnostics ---

        def diagnostic_for(matcher_call, anchor, entry)
          lane = MATCHER_TABLE.fetch(matcher_call.name)
          target = matcher_call.arguments.arguments.first.unescaped.to_sym

          case lane
          when :column
            column_violation(matcher_call, anchor, entry, target)
          when :association_singular
            association_violation(matcher_call, anchor, entry, target, expected_kind: :singular)
          when :association_collection
            association_violation(matcher_call, anchor, entry, target, expected_kind: :collection)
          end
        end

        # `entry` is the published fact's per-model Hash: `{ table:, columns:, associations:, ... }`.
        # `columns:` is a flat `Array<String>` (`Activerecord#index_to_published_hash`); `associations:` is
        # `Array<Hash>` with String `:name`, Symbol `:kind` (`:singular` | `:collection`), `:nullable`,
        # `:polymorphic`, and a `:target` that is a String except on polymorphic rows, where it is nil —
        # the row shape `ModelDiscoverer#build_association_row` publishes. Only `:name` and `:kind` are
        # read here.
        def column_names(entry) = entry[:columns] || []
        def association_rows(entry) = entry[:associations] || []
        def find_association(entry, name) = association_rows(entry).find { |a| a[:name] == name.to_s }

        def column_violation(matcher_call, anchor, entry, column_name)
          return nil if column_names(entry).include?(column_name.to_s)

          Violation.new(
            rule: "unknown-column",
            message: "#{matcher_call.name}(:#{column_name}) — no column `#{column_name}` on " \
                     "#{anchor} (columns: #{column_names(entry).sort.join(', ')})"
          )
        end

        def association_violation(matcher_call, anchor, entry, assoc_name, expected_kind:)
          association = find_association(entry, assoc_name)
          if association
            actual = association[:kind]
            return nil if actual == expected_kind

            Violation.new(
              rule: "association-kind-mismatch",
              message: "#{matcher_call.name}(:#{assoc_name}) on #{anchor} — `#{assoc_name}` is " \
                       "a #{actual} association; #{matcher_call.name} expects #{expected_kind}"
            )
          else
            known = association_rows(entry).map { |a| a[:name] }
            Violation.new(
              rule: "unknown-association",
              message: "#{matcher_call.name}(:#{assoc_name}) — no association `#{assoc_name}` on " \
                       "#{anchor} (associations: #{known.sort.join(', ')})"
            )
          end
        end
      end
    end
  end
end
