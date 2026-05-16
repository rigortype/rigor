# frozen_string_literal: true

require "prism"

require_relative "uri"
require_relative "../environment"
require_relative "../scope"
require_relative "../source/node_locator"
require_relative "../inference/scope_indexer"

module Rigor
  module LanguageServer
    # Answers `textDocument/hover` requests by running the same
    # NodeLocator + ScopeIndexer + `Scope#type_of` chain that
    # `rigor type-of` already drives. The LSP wraps the result in a
    # `Hover` payload with markdown contents.
    #
    # Per LSP spec § "Position":
    # - `line` and `character` are 0-based.
    # - `character` counts UTF-16 code units; v1 emits byte counts
    #   for ASCII source (UTF-16 conversion is queued, see design
    #   doc § "Open questions").
    class HoverProvider
      def initialize(buffer_table:, configuration:)
        @buffer_table = buffer_table
        @configuration = configuration
      end

      # @return [Hash, nil] an LSP `Hover` payload or nil when no
      #   expression sits at the queried position. Returning nil
      #   maps to `result: null` per the LSP spec — clients
      #   suppress the hover popup in that case.
      def provide(uri:, line:, character:)
        path = Uri.to_path(uri)
        return nil if path.nil?

        entry = @buffer_table[uri]
        return nil if entry.nil?

        parse_result = Prism.parse(entry.bytes, filepath: path, version: @configuration.target_ruby)
        return nil unless parse_result.errors.empty?

        # Rigor's NodeLocator uses 1-based line / column; LSP uses
        # 0-based. Translate at the boundary.
        node = locate_node(source: entry.bytes, root: parse_result.value, line: line + 1, character: character + 1)
        return nil if node.nil?

        scope = base_scope(path)
        index = Inference::ScopeIndexer.index(parse_result.value, default_scope: scope)
        node_scope = index[node]
        type = node_scope.type_of(node)

        build_hover(type: type, node: node)
      end

      private

      def locate_node(source:, root:, line:, character:)
        Source::NodeLocator.at_position(source: source, root: root, line: line, column: character)
      rescue Source::NodeLocator::OutOfRangeError
        nil
      end

      def base_scope(_path)
        # Slice 5 builds a fresh Environment per request. Slice 7
        # (ProjectContext) caches the Environment across requests
        # so hovers don't pay the RBS-load tax every time.
        Scope.empty(environment: Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths
        ))
      end

      # Builds the LSP `Hover` payload. `contents` is `MarkupContent`
      # with `kind: "markdown"` containing the inferred type and its
      # RBS-erased form, formatted as a fenced code block so editors
      # syntax-highlight it. Mirrors the human-readable shape of
      # `rigor type-of`'s text output.
      def build_hover(type:, node:)
        body = +"```ruby\n"
        body << "type:   #{type.describe}\n"
        body << "erased: #{type.erase_to_rbs}\n"
        body << "node:   #{node.class}\n"
        body << "```"

        { contents: { kind: "markdown", value: body } }
      end
    end
  end
end
