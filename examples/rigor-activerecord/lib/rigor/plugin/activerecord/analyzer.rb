# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Per-file AST walker. For each `Model.find(...)` /
      # `Model.find_by(...)` / `Model.where(...)` call where
      # `Model` is a name in the {ModelIndex}, emits diagnostics:
      #
      # | Method | Recognised arg shape | Validation |
      # | --- | --- | --- |
      # | `Model.find(id)` | any positional | arity check (1+ args) |
      # | `Model.find_by(col: v, ...)` | keyword args | each key must be a column |
      # | `Model.where(col: v, ...)` | keyword args | each key must be a column |
      # | `Model.where(string)` | String literal | parser-side; not validated |
      #
      # Successful matches surface as `:info` diagnostics naming
      # the resolved table; unknown columns surface as `:error`.
      # Calls whose receiver is not a model in the index, and
      # calls with non-keyword arguments to `where` / `find_by`,
      # stay silent.
      class Analyzer
        # Methods that take a column → value Hash and need each key
        # validated against the receiver's column set.
        COLUMN_HASH_METHODS = %i[where find_by find_or_create_by find_or_initialize_by].freeze

        DID_YOU_MEAN_DISTANCE = 3

        attr_reader :diagnostics

        def initialize(path:, model_index:)
          @path = path
          @model_index = model_index
          @diagnostics = []
        end

        def analyze(root)
          walk(root) { |node| visit_call(node) if node.is_a?(Prism::CallNode) }
          self
        end

        private

        def walk(node, &block)
          return if node.nil?

          yield node
          node.compact_child_nodes.each { |child| walk(child, &block) }
        end

        def visit_call(node)
          model_name = constant_receiver_name(node.receiver)
          return if model_name.nil?

          entry = @model_index.find(model_name) ||
                  @model_index.find("::#{model_name}")
          return if entry.nil?

          case node.name
          when :find then validate_find(node, entry)
          when *COLUMN_HASH_METHODS then validate_column_hash_call(node, entry)
          end
        end

        def validate_find(node, entry)
          arity = call_argument_count(node)
          if arity.zero?
            push_error(node, "wrong-arity",
                       "`#{entry.class_name}.find` expects at least 1 argument, got 0")
            return
          end

          push_info(node, "model-call",
                    "`#{entry.class_name}.find` returns #{entry.class_name} (table: `#{entry.table_name}`)")
        end

        def validate_column_hash_call(node, entry)
          keyword_keys = keyword_argument_keys(node)
          return push_recognised(node, entry) if keyword_keys.empty?

          unknown = keyword_keys.reject { |k| entry.column?(k) }
          if unknown.empty?
            push_recognised(node, entry, keyword_keys)
          else
            unknown.each do |key|
              suggestion = closest_column(key, entry.column_names)
              hint = suggestion ? " (did you mean `:#{suggestion}`?)" : ""
              push_error(node, "unknown-column",
                         "`#{entry.class_name}.#{node.name}(#{key}: ...)` references " \
                         "unknown column `#{key}` on table `#{entry.table_name}`#{hint}")
            end
          end
        end

        def push_recognised(node, entry, keys = nil)
          msg = "`#{entry.class_name}.#{node.name}`"
          msg += " (#{keys.map { |k| ":#{k}" }.join(", ")})" if keys && !keys.empty?
          msg += " on table `#{entry.table_name}`"
          push_info(node, "model-call", msg)
        end

        def constant_receiver_name(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            constant_path_name(node)
          end
        end

        def constant_path_name(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          case current
          when nil
            "::#{parts.join("::")}"
          when Prism::ConstantReadNode
            "#{current.name}::#{parts.join("::")}"
          end
        end

        def call_argument_count(node)
          return 0 if node.arguments.nil?

          node.arguments.arguments.size
        end

        # Returns the symbol keys of any KeywordHashNode argument.
        # Plain hash-literal arguments (`Model.where({a: 1})`) are
        # NOT walked — Rails accepts both, but the keyword form is
        # the idiomatic one.
        def keyword_argument_keys(node)
          return [] if node.arguments.nil?

          keys = []
          node.arguments.arguments.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |pair|
              next unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode)

              keys << pair.key.unescaped
            end
          end
          keys
        end

        def closest_column(name, candidates)
          best = nil
          best_distance = DID_YOU_MEAN_DISTANCE + 1
          candidates.each do |candidate|
            distance = levenshtein(name, candidate)
            if distance < best_distance
              best = candidate
              best_distance = distance
            end
          end
          best
        end

        def levenshtein(a, b) # rubocop:disable Naming/MethodParameterName,Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          return b.length if a.empty?
          return a.length if b.empty?

          rows = Array.new(a.length + 1) { |i| Array.new(b.length + 1, 0) }
          (0..a.length).each { |i| rows[i][0] = i }
          (0..b.length).each { |j| rows[0][j] = j }

          (1..a.length).each do |i|
            (1..b.length).each do |j|
              cost = a[i - 1] == b[j - 1] ? 0 : 1
              rows[i][j] = [
                rows[i - 1][j] + 1,
                rows[i][j - 1] + 1,
                rows[i - 1][j - 1] + cost
              ].min
            end
          end
          rows[a.length][b.length]
        end

        def push_info(node, rule, message)
          push_diagnostic(node, severity: :info, rule: rule, message: message)
        end

        def push_error(node, rule, message)
          push_diagnostic(node, severity: :error, rule: rule, message: message)
        end

        def push_diagnostic(node, severity:, rule:, message:)
          location = node.location
          @diagnostics << Rigor::Analysis::Diagnostic.new(
            path: @path,
            line: location.start_line,
            column: location.start_column + 1,
            message: message,
            severity: severity,
            rule: rule
          )
        end
      end
    end
  end
end
