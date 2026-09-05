# frozen_string_literal: true

require "prism"

require_relative "method_key"

module Rigor
  module Effects
    # Where a method key's `def` is written, resolved from the file the key was already traced to
    # (#435).
    #
    # A drift row names the file out of `Runner#effect_sources`, which rides the cached summary entry
    # and is therefore free. The **line** is not in any value the effects surfaces hold: the discovery
    # tables {EnvelopeCheck::Positions} reads are built by one Prism parse of every project file, which
    # is exactly what [ADR-104](../../../docs/adr/104-effects-boot-slim-probe.md) removed from this
    # command — a warm `rigor effects check` is fast *because* it never parses the project.
    #
    # So this parses the drift's own files and nothing else: an index is built the first time a row asks
    # about a path, and a report with no rows builds none. The cost is proportional to the drift, not to
    # the project — the {EnvelopeCheck::DeferredPositions} shape (#479) applied one layer up, and the
    # reason it can be one layer up is that the caller already knows the file.
    #
    # It is deliberately not a second discovery pass. It answers `def`s and only `def`s: a key whose
    # method has no Ruby `def` at all — a synthesized accessor — keeps the file and loses the line,
    # which is the same degradation `Positions` makes when it falls back to the class's own source.
    class DefinitionLines
      TOPLEVEL = "<toplevel>"
      private_constant :TOPLEVEL

      NO_LINES = {}.freeze
      private_constant :NO_LINES

      # @rbs key: String -- An effect unit key — `Tracer::Loud#emit`, `Net::HTTP.get`.
      # @rbs path: String -- The file the key was traced to.
      # @rbs return: Integer? --
      #   The `def`'s line, or nil when this file does not spell that key with a `def` — an unreadable file, a syntax
      #   error, and a synthesized method all land here.
      def for(key:, path:)
        index_for(path)[key]
      end

      private

      def index_for(path)
        @indexes ||= {}
        @indexes[path] ||= build_index(path)
      end

      # First `def` wins: a file that reopens the same method twice has two lines and only one of them is
      # where a reader starts.
      def build_index(path)
        result = Prism.parse_file(path.to_s)
        return NO_LINES unless result.success?

        {}.tap { |index| walk(result.value, [], singleton: false, index: index) }
      rescue StandardError
        NO_LINES
      end

      # The nesting is tracked, never resolved: `class Tracer::Loud` inside `module Tracer` spells a key
      # this cannot see, and answering it would need the constant resolution an engine-free path does not
      # have. A key it cannot spell keeps its file, which is what the row printed before this class existed.
      def walk(node, nesting, singleton:, index:)
        case node
        when Prism::ModuleNode, Prism::ClassNode
          name = constant_name(node.constant_path)
          return if name.nil?

          walk_children(node.body, nesting + [name], singleton: false, index: index)
        when Prism::SingletonClassNode
          walk_children(node.body, nesting, singleton: true, index: index)
        when Prism::DefNode
          record(node, nesting, singleton: singleton, index: index)
          walk_children(node.body, nesting, singleton: singleton, index: index)
        else
          walk_children(node, nesting, singleton: singleton, index: index)
        end
      end

      def walk_children(node, nesting, singleton:, index:)
        node&.compact_child_nodes&.each { |child| walk(child, nesting, singleton: singleton, index: index) }
      end

      def record(node, nesting, singleton:, index:)
        separator = singleton || node.receiver.is_a?(Prism::SelfNode) ? "." : "#"
        owner = nesting.empty? ? TOPLEVEL : nesting.join("::")
        key = "#{owner}#{separator}#{node.name}"
        index[key] ||= node.location.start_line
      end

      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then node.full_name
        end
      rescue StandardError
        nil
      end
    end
  end
end
