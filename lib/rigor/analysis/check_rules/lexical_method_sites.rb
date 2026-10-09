# frozen_string_literal: true

require "prism"

require_relative "../../inference/scope_indexer"
require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # Issue #1120 — the two ways one file makes a method callable at some sites and not at others, which
      # `call.undefined-method` has to ask the file's syntax about because no project-wide table can answer:
      #
      # - **Refinements.** Issue #1673 — answered by the file's in-effect refinements ({#refinements}, an
      #   {Inference::InEffectRefinements}), the ordered list the typer reads too; the rules ask it for derived
      #   answers (`refinement_active?`, `any_at?`, `refinement_def?`).
      # - **Singleton defs on locals.** `def o.m` defines `m` on the one object `o` holds. The local's type
      #   is not changed; `o.m` is simply not reported within the scope the `def` is written in (the
      #   enclosing `def`, `class` / `module` body, or file — a block shares its enclosing scope's locals).
      #
      # Built lazily: the walk runs the first time a would-fire call asks, so a file with no such call pays
      # one small object and nothing else.
      class LexicalMethodSites
        # Issue #1703 — the file's root, which `call.possible-nil-receiver` re-walks for a `key?` guard.
        attr_reader :root
        attr_reader :refinements

        def initialize(root)
          @root = root
          @built = false
          @refinements = Inference::InEffectRefinements.new(root)
        end

        # Does a `def <local>.<name>` for this call's local receiver and method name sit in the scope the call
        # is in?
        def singleton_local_def?(call_node)
          receiver = call_node.receiver
          return false unless receiver.is_a?(Prism::LocalVariableReadNode)

          build
          offset = call_node.location.start_offset
          @singleton_defs.any? do |local, method_name, start, stop|
            local == receiver.name && method_name == call_node.name && offset >= start && offset < stop &&
              !nested_scope_holds?(offset, start, stop)
          end
        end

        private

        # Is `offset` inside a local scope nested in the one `[start, stop)` spans? A `def` in the file's top level
        # does not see the top level's `o`.
        def nested_scope_holds?(offset, start, stop)
          @scopes.any? do |inner_start, inner_stop|
            (inner_start > start || inner_stop < stop) && inner_start >= start && inner_stop <= stop &&
              offset >= inner_start && offset < inner_stop
          end
        end

        def build
          return if @built

          @built = true
          @singleton_defs = []
          @scopes = []
          return if @root.nil?

          location = @root.location
          span = [location.start_offset, location.end_offset]
          walk(@root, span)
        end

        # `locals` is the span of the scope a local written here belongs to.
        def walk(node, locals)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            return walk_children(node.body, scope_span(node))
          when Prism::SingletonClassNode
            walk(node.expression, locals)
            return walk_children(node.body, scope_span(node))
          when Prism::DefNode
            record_singleton_def(node, locals)
            return walk_children(node.body, scope_span(node))
          end

          walk_children(node, locals)
        end

        def walk_children(node, locals)
          return if node.nil?

          node.rigor_each_child { |child| walk(child, locals) }
        end

        def record_singleton_def(node, locals)
          receiver = node.receiver
          return unless receiver.is_a?(Prism::LocalVariableReadNode)

          @singleton_defs << [receiver.name, node.name, *locals]
        end

        # The span of a node that opens a local scope, recorded for {#nested_scope_holds?}.
        def scope_span(node)
          span = span_of(node)
          @scopes << span
          span
        end

        def span_of(node)
          location = node.location
          [location.start_offset, location.end_offset]
        end
      end
    end
  end
end
