# frozen_string_literal: true

require_relative "node_context"
require_relative "../source/node_walker"

module Rigor
  module Plugin
    # ADR-52 WD4 — one engine-owned AST walk per file for node rules.
    #
    # Before this, every plugin that declared a {Base.node_rule} walked
    # the file's AST itself (`Base#node_rule_diagnostics` →
    # `Source::NodeWalker.each_with_ancestors`), so a project with N
    # node-rule plugins paid N walks per file. This folds them into a
    # single walk that dispatches each visited node to every matching
    # `(plugin, rule)` pair.
    #
    # Behaviour is preserved exactly so the diagnostics stay
    # byte-identical (the WD6 gate):
    #
    # * Each plugin's `node_file_context` block runs once per file,
    #   before any of its rules fire, `instance_exec`'d on that plugin —
    #   same as the per-plugin walk.
    # * One frozen {NodeContext} is built per node, lazily, only when at
    #   least one rule matches it. Because it wraps only the ancestors it
    #   is safe to share across plugins for the same node.
    # * Each rule block is `instance_exec`'d on its own plugin instance
    #   with the same five arguments `(node, scope, path, file_context,
    #   context)`.
    # * A plugin whose context block or any rule block raises has its
    #   whole node-rule contribution isolated — the walk records the
    #   error against that plugin and continues, matching the runner's
    #   per-plugin rescue around the old `#node_rule_diagnostics` call.
    # * Diagnostics are bucketed per plugin and returned in the
    #   registry order the runner already iterates, so emission order is
    #   unchanged (plugin-major, not node-major) — order preservation is
    #   what keeps the gate byte-identical in this slice.
    #
    # The result is an ordered Array of {Result}, one per node-rule
    # plugin (registry order). `Result#error` is non-nil iff that
    # plugin's context or a rule block raised, in which case
    # `#diagnostics` is empty; the runner turns the error into the same
    # per-plugin `runtime-error` envelope it produced before.
    class NodeRuleWalk
      # One plugin's node-rule outcome for a single file. `error` is the
      # exception raised by the plugin's context block or a rule block
      # (nil on success); when set, `diagnostics` is empty.
      Result = Struct.new(:plugin, :diagnostics, :error)

      # Plugins that declare at least one `node_rule`, paired with their
      # frozen rule list, in registry order. Built once per run and
      # reused for every file.
      def initialize(plugins)
        @entries = plugins.filter_map do |plugin|
          rules = plugin.class.node_rules
          rules.empty? ? nil : [plugin, rules]
        end.freeze
        freeze
      end

      def empty?
        @entries.empty?
      end

      # Walk `root` once, dispatching every node to each matching
      # `(plugin, rule)`. Returns an Array of {Result} in plugin
      # (registry) order. `root` nil yields one empty Result per plugin.
      def diagnostics_for_file(path:, scope:, root:)
        return @entries.map { |plugin, _| Result.new(plugin, [], nil) } if root.nil?

        states = @entries.map { |plugin, rules| State.new(plugin, rules, scope, root) }
        walk(path, scope, root, states)
        states.map(&:result)
      end

      private

      def walk(path, scope, root, states)
        Source::NodeWalker.each_with_ancestors(root) do |node, ancestors|
          context = nil
          states.each do |state|
            next if state.failed?

            matched = state.rules_for(node)
            next if matched.empty?

            # One frozen NodeContext per node, built lazily and shared
            # across every plugin that matches this node.
            context ||= NodeContext.new(ancestors)
            state.run_rules(matched, node, scope, path, context)
          end
        end
      end

      # Mutable per-(plugin, file) walk state. Kept private to the walk —
      # holds the diagnostics bucket, the file context, the per-concrete-
      # class match memo, and the isolation flag.
      class State
        def initialize(plugin, rules, scope, root)
          @plugin = plugin
          @rules = rules
          @diagnostics = []
          @match_cache = {}.compare_by_identity
          @error = nil
          build_file_context(scope, root)
        end

        def failed?
          !@error.nil?
        end

        # Rules whose `node_type` this concrete node satisfies, memoised
        # by the node's class so the `is_a?` scan runs once per class.
        # Preserves `is_a?` semantics when a rule's `node_type` is a
        # superclass of the concrete node.
        def rules_for(node)
          @match_cache[node.class] ||=
            @rules.select { |rule| node.is_a?(rule[:node_type]) }
        end

        def run_rules(matched, node, scope, path, context)
          matched.each do |rule|
            result = @plugin.instance_exec(node, scope, path, @file_context, context, &rule[:block])
            @diagnostics.concat(Array(result))
          end
        rescue StandardError => e
          @error = e
          @diagnostics = []
        end

        def result
          NodeRuleWalk::Result.new(@plugin, @diagnostics, @error)
        end

        private

        def build_file_context(scope, root)
          block = @plugin.class.node_file_context_block
          @file_context = block ? @plugin.instance_exec(root, scope, &block) : nil
        rescue StandardError => e
          @error = e
          @file_context = nil
        end
      end
      private_constant :State
    end
  end
end
