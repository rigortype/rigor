# frozen_string_literal: true

require_relative "../../flow_contribution"
require_relative "../../flow_contribution/merger"

module Rigor
  module Inference
    module MethodDispatcher
      # The plugin contribution tier (ADR-2 § "Flow Contribution Bundle", v0.1.1 Track 2 slice 7): the return type
      # the loaded plugins' gated `dynamic_return` rules contribute for one call, merged. `MethodDispatcher.resolve`
      # asks it ahead of `RbsDispatch` and records its answer on the scope, so it is a call there and a member of no
      # tier array.
      module PluginContribution
        module_function

        # The tier, as `resolve` asks it: the merged contribution for the site's call node, scope and receiver. It
        # declines a site without a call node or a scope, which is every dispatch the engine makes for itself (a
        # per-element block fold, an alias target).
        def try_dispatch(context)
          merged_return_type(context.call_node, context.scope, context.receiver)
        end

        # ADR-2 § "Flow Contribution Bundle" / v0.1.1 Track 2 slice 7; ADR-52 WD3 — consults each
        # loaded plugin's gated `dynamic_return` rules, wraps the contributed types as
        # `FlowContribution` bundles, merges them through `FlowContribution::Merger`, and returns
        # the merged `return_type` slot (or nil when no plugin contributed a return type).
        #
        # Plugins whose hook raises have their contribution silently dropped for this call so the
        # dispatch chain keeps moving — the run-level diagnostic envelope (per ADR-2 § "Plugin
        # Trust and I/O Policy") is owned by `Analysis::Runner#plugin_emitted_diagnostics`.
        #
        # The tier's second entry: `MethodDispatcher.plugin_member_answers?` asks it with the three values it holds
        # (the veto has no `CallContext`), and {#try_dispatch} with the same three read from the site.
        def merged_return_type(call_node, scope, receiver_type)
          return nil if call_node.nil? || scope.nil?

          registry = scope.environment&.plugin_registry
          return nil if registry.nil? || registry.empty?

          contributions = collect_plugin_contributions(registry, call_node, scope, receiver_type)
          return nil if contributions.empty?

          FlowContribution::Merger.merge(contributions).return_type
        end

        # ADR-37 slice 2 / ADR-52 WD3 — gathers each plugin's return-type contribution from the
        # gated `dynamic_return` DSL, wrapped as a return-only `FlowContribution` for the shared
        # merger. (The legacy ungated `flow_contribution_for` escape valve was deleted once its
        # five users migrated.)
        EMPTY_CONTRIBUTIONS = [].freeze
        private_constant :EMPTY_CONTRIBUTIONS

        # Collects every plugin's flow / dynamic-return contribution for one call site. Three
        # prunings keep this off the hot path on plugin-heavy projects (it was the #1 allocation
        # site and a top CPU cost):
        #
        # 1. Only the plugins that *structurally* implement a per-call path are visited —
        #    `registry.contribution_index.for_method_dispatch` is the registry-ordered subset
        #    declaring a `dynamic_return`. Iterating the subset in registry order, and gating each
        #    path by membership, yields the exact same contributions in the same order as visiting
        #    every plugin would (a skipped plugin's call returns nil/[] anyway). The
        #    receiver-class ancestry match still happens per dispatch inside `dynamic_return_type`.
        # 2. Contributions accumulate lazily — allocate only when one actually appears, and share a
        #    frozen empty array otherwise. The caller treats the result as read-only (`.empty?` /
        #    `Merger.merge`).
        # 3. ADR-52 WD1 — method-name gates compiled at registry build. The global gate makes the
        #    common "no plugin cares about this call" case a single Set probe; the per-plugin gate
        #    skips a plugin whose `dynamic_return` rules are all `methods:`-gated on other names. A
        #    pruned consultation could only have returned nil, so contribution order and content
        #    are unchanged.
        def collect_plugin_contributions(registry, call_node, scope, receiver_type)
          index = registry.contribution_index
          relevant = index.for_method_dispatch
          return EMPTY_CONTRIBUTIONS if relevant.empty?

          # `call_node` is not always a CallNode — the `&:symbol` block path dispatches with the
          # `Prism::BlockArgumentNode` itself (`ExpressionTyper#symbol_block_return_type`). A bare
          # `.name` here raised, and the raise was silently absorbed by `block_return_type_for`'s
          # rescue, nil-ing the block type and flipping `select(&:p)`-style calls onto their
          # no-block Enumerator overloads (caught by the GitLab corpus gate).
          name = call_node.respond_to?(:name) ? call_node.name : nil
          return EMPTY_CONTRIBUTIONS unless index.dispatch_candidate?(name)

          collect_gated_contributions(index, relevant, name, call_node, scope, receiver_type)
        end

        # The post-gate walk, in registry order — the same order the ungated walk used.
        def collect_gated_contributions(index, relevant, name, call_node, scope, receiver_type)
          result = nil
          relevant.each do |plugin|
            next unless index.dynamic_candidate_for?(plugin, name)

            dynamic = plugin.dynamic_return_type(call_node: call_node, scope: scope, receiver_type: receiver_type)
            (result ||= []) << FlowContribution.new(return_type: dynamic) if dynamic
          rescue StandardError
            next
          end
          result || EMPTY_CONTRIBUTIONS
        end
      end
    end
  end
end
