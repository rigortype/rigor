# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class ShouldaMatchers < Rigor::Plugin::Base
      # Walks every `RSpec.describe <ModelConst> do ... end` /
      # `describe <ModelConst> do ... end` block and validates
      # the shoulda-matchers calls inside its body (any depth
      # of nested `describe` / `context`) against the
      # `:model_index` published by `rigor-activerecord`.
      #
      # The "anchor" for cross-checking is the OUTERMOST
      # describe block whose argument is a constant — that
      # constant names the model being specced. Nested
      # `describe ".some_method"` (String / Symbol args) does
      # NOT change the anchor.
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
      #   allow_value(...).for(:col)
      #   have_db_column(:col)
      #   have_db_index(:col)
      #
      # All look up `:col` against the model's columns
      # (`Entry#column?`). Unknown columns fire
      # `shoulda-matchers.unknown-column`.
      #
      # ### Association matchers
      #
      #   belong_to(:assoc)           ← expects :singular
      #   have_one(:assoc)            ← expects :singular
      #   have_many(:assoc)           ← expects :collection
      #   have_and_belong_to_many(:assoc) ← expects :collection
      #
      # Unknown associations fire
      # `shoulda-matchers.unknown-association`. Known
      # associations with mismatched kind (`should belong_to(:posts)`
      # where `:posts` is `has_many`) fire
      # `shoulda-matchers.association-kind-mismatch`.
      module Analyzer
        Diagnostic = Struct.new(:path, :line, :column, :severity, :rule, :message, keyword_init: true)

        # `(matcher_name) => (:column | :association_singular | :association_collection)`
        # — the validation lane each matcher routes to.
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
          # Association matchers — validate the association
          # exists AND its kind matches the matcher.
          belong_to: :association_singular,
          have_one: :association_singular,
          have_many: :association_collection,
          have_and_belong_to_many: :association_collection
        }.freeze

        module_function

        # @param path [String]
        # @param root [Prism::Node]
        # @param model_index [Object, nil] the `:model_index`
        #   fact value. When nil the analyzer falls silent.
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, model_index:)
          return [] if model_index.nil?

          diagnostics = []
          walk_describe(root, anchor_model: nil) do |matcher_call, anchor|
            entry = model_index.find(anchor)
            next if entry.nil?

            diagnostic = diagnostic_for(matcher_call, path, anchor, entry)
            diagnostics << diagnostic if diagnostic
          end
          diagnostics
        end

        # Walks for `RSpec.describe(Const)` / `describe(Const)`
        # blocks (the Const is the model anchor) and yields
        # every matcher call found in their body.
        #
        # The anchor stays the OUTERMOST describe-with-const
        # — nested describes / contexts inherit it without
        # overriding (a nested `describe ".active"` is not a
        # model constant). When a nested describe DOES name a
        # different model, the nested anchor wins inside that
        # subtree (rare; we still honour it).
        def walk_describe(node, anchor_model:, &)
          return unless node.is_a?(Prism::Node)

          if describe_with_constant?(node)
            inner_anchor = describe_const_name(node) || anchor_model
            collect_matchers(node.block.body, inner_anchor, &) if node.block&.body
            return
          end

          node.compact_child_nodes.each do |child|
            walk_describe(child, anchor_model: anchor_model, &)
          end
        end

        # Walks the body of a describe block looking for:
        #   (a) matcher calls — `should MATCHER` or
        #       `expect(...).to MATCHER` chains; we yield the
        #       inner MATCHER call.
        #   (b) nested describe / context blocks — we recurse
        #       so deeper matchers are reachable.
        def collect_matchers(body, anchor, &)
          return unless body.is_a?(Prism::Node)
          return if anchor.nil?

          if matcher_invocation?(body)
            yield body, anchor
            return
          end

          if describe_with_constant?(body)
            inner_anchor = describe_const_name(body) || anchor
            collect_matchers(body.block.body, inner_anchor, &) if body.block&.body
            return
          end

          body.compact_child_nodes.each do |child|
            collect_matchers(child, anchor, &)
          end
        end

        # A direct matcher invocation is a `CallNode` whose
        # `name` is in `MATCHER_TABLE` and whose first argument
        # is a `SymbolNode`. The chain shape (`should`,
        # `expect(...).to`, `is_expected.to`) is irrelevant —
        # we always recurse to the inner matcher, so a
        # diagnostic fires on the matcher regardless of the
        # surrounding chain.
        def matcher_invocation?(node)
          node.is_a?(Prism::CallNode) && MATCHER_TABLE.key?(node.name) && symbol_first_arg?(node)
        end

        def symbol_first_arg?(call_node)
          args = call_node.arguments&.arguments || []
          !args.empty? && args.first.is_a?(Prism::SymbolNode)
        end

        # Detects `RSpec.describe(Const) do ... end` and
        # `describe(Const) do ... end`. Either form opens a
        # scope whose anchor is `Const`. The receiver shape
        # (RSpec vs nil) is allowed in both cases.
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
            when nil then "::#{parts.join('::')}"
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end

        # --- diagnostics ---

        def diagnostic_for(matcher_call, path, anchor, entry)
          lane = MATCHER_TABLE.fetch(matcher_call.name)
          target = matcher_call.arguments.arguments.first.unescaped.to_sym

          case lane
          when :column
            column_diagnostic(matcher_call, path, anchor, entry, target)
          when :association_singular
            association_diagnostic(matcher_call, path, anchor, entry, target, expected_kind: :singular)
          when :association_collection
            association_diagnostic(matcher_call, path, anchor, entry, target, expected_kind: :collection)
          end
        end

        def column_diagnostic(matcher_call, path, anchor, entry, column_name)
          return nil if entry.column?(column_name)

          build_diagnostic(
            matcher_call, path,
            rule: "shoulda-matchers.unknown-column",
            message: "#{matcher_call.name}(:#{column_name}) — no column `#{column_name}` on " \
                     "#{anchor} (columns: #{entry.column_names.sort.join(', ')})"
          )
        end

        def association_diagnostic(matcher_call, path, anchor, entry, assoc_name, expected_kind:)
          if entry.association?(assoc_name)
            actual = entry.association(assoc_name)[:kind]
            return nil if actual == expected_kind

            build_diagnostic(
              matcher_call, path,
              rule: "shoulda-matchers.association-kind-mismatch",
              message: "#{matcher_call.name}(:#{assoc_name}) on #{anchor} — `#{assoc_name}` is " \
                       "a #{actual} association; #{matcher_call.name} expects #{expected_kind}"
            )
          else
            build_diagnostic(
              matcher_call, path,
              rule: "shoulda-matchers.unknown-association",
              message: "#{matcher_call.name}(:#{assoc_name}) — no association `#{assoc_name}` on " \
                       "#{anchor} (associations: #{entry.association_names.sort.join(', ')})"
            )
          end
        end

        def build_diagnostic(call_node, path, rule:, message:)
          location = call_node.message_loc || call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :warning,
            rule: rule,
            message: message
          )
        end
      end
    end
  end
end
