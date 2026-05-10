# frozen_string_literal: true

require "did_you_mean"
require "prism"

module Rigor
  module Plugin
    class Factorybot < Rigor::Plugin::Base
      # Per-file walker — visits every `FactoryBot.<entry>(...)`
      # call (and the `FactoryGirl` legacy alias) and validates
      # the factory name + the keyword-argument attribute keys
      # against the per-run {FactoryIndex}.
      #
      # Recognised entry methods cover the canonical create /
      # build / build_stubbed / attributes_for family; the same
      # validation applies to every entry (the runtime semantics
      # differ — one persists, one returns a hash — but the
      # call-site shape is identical from the static check's
      # perspective).
      module Analyzer
        ENTRY_METHODS = %i[create build build_stubbed attributes_for create_list build_list build_stubbed_list].freeze

        Diagnostic = Data.define(:path, :line, :column, :message, :severity, :rule)

        module_function

        def diagnose(path:, root:, factory_index:)
          diagnostics = []
          spell_checker = DidYouMean::SpellChecker.new(dictionary: factory_index.names)

          walk_entry_calls(root) do |call_node|
            factory_name = first_positional_symbol_or_string(call_node)
            next if factory_name.nil?

            entry = factory_index.find(factory_name)
            diagnostics.concat(diagnostics_for_call(path, call_node, factory_name, entry, spell_checker))
          end

          diagnostics
        end

        # Walk the AST yielding only call nodes whose receiver
        # is `FactoryBot` (or the `FactoryGirl` legacy alias)
        # and whose method name is in {ENTRY_METHODS}.
        def walk_entry_calls(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if entry_call?(node)
          node.compact_child_nodes.each { |child| walk_entry_calls(child, &) }
        end

        def entry_call?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless ENTRY_METHODS.include?(node.name)

          factorybot_receiver?(node.receiver)
        end

        def factorybot_receiver?(receiver)
          return false unless receiver.is_a?(Prism::ConstantReadNode) ||
                              receiver.is_a?(Prism::ConstantPathNode)

          name = case receiver
                 when Prism::ConstantReadNode then receiver.name.to_s
                 when Prism::ConstantPathNode then receiver.name.to_s
                 end
          %w[FactoryBot FactoryGirl].include?(name)
        end

        def first_positional_symbol_or_string(call_node)
          first_arg = call_node.arguments&.arguments&.first
          case first_arg
          when Prism::SymbolNode then first_arg.value
          when Prism::StringNode then first_arg.unescaped
          end
        end

        def diagnostics_for_call(path, call_node, factory_name, entry, spell_checker)
          return [unknown_factory_diagnostic(path, call_node, factory_name, spell_checker)] if entry.nil?

          unknown_attribute_diagnostics(path, call_node, entry) +
            [factory_call_diagnostic(path, call_node, factory_name, entry)]
        end

        # The keyword-argument attribute keys come from the
        # trailing `Prism::KeywordHashNode` (Ruby's
        # `name: "value"` syntax). Each AssocNode whose key is
        # a `Prism::SymbolNode` is treated as a literal
        # attribute reference.
        def unknown_attribute_diagnostics(path, call_node, entry)
          attr_spell_checker = DidYouMean::SpellChecker.new(dictionary: entry.attribute_names)
          attribute_assoc_nodes(call_node).filter_map do |assoc|
            next unless assoc.key.is_a?(Prism::SymbolNode)

            attr_name = assoc.key.value
            next if entry.attribute_names.include?(attr_name)

            unknown_attribute_diagnostic(path, assoc, entry, attr_name, attr_spell_checker)
          end
        end

        def attribute_assoc_nodes(call_node)
          args = call_node.arguments&.arguments || []
          last = args.last
          return [] unless last.is_a?(Prism::KeywordHashNode)

          last.elements.grep(Prism::AssocNode)
        end

        def factory_call_diagnostic(path, call_node, factory_name, entry)
          loc = call_node.message_loc || call_node.location
          attrs = entry.attribute_names.empty? ? "(no attributes)" : entry.attribute_names.join(", ")
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: "FactoryBot.#{call_node.name}(:#{factory_name}) — declared attributes: #{attrs}.",
            severity: :info, rule: "factory-call"
          )
        end

        def unknown_factory_diagnostic(path, call_node, factory_name, spell_checker)
          loc = call_node.message_loc || call_node.location
          base = "FactoryBot.#{call_node.name}(:#{factory_name}) — factory not declared in any " \
                 "factory_search_paths file."
          suggestion = spell_checker.correct(factory_name).first
          message = suggestion ? "#{base} Did you mean `:#{suggestion}`?" : base
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: message, severity: :error, rule: "unknown-factory"
          )
        end

        def unknown_attribute_diagnostic(path, assoc, entry, attr_name, spell_checker)
          loc = assoc.key.location
          base = "FactoryBot factory `:#{entry.name}` has no declared attribute `:#{attr_name}`."
          suggestion = spell_checker.correct(attr_name).first
          message = suggestion ? "#{base} Did you mean `:#{suggestion}`?" : base
          Diagnostic.new(
            path: path, line: loc.start_line, column: loc.start_column + 1,
            message: message, severity: :error, rule: "unknown-attribute"
          )
        end
      end
    end
  end
end
