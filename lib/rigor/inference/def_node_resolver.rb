# frozen_string_literal: true

require "prism"
require_relative "def_handle"
require_relative "../source/node_children"

module Rigor
  module Inference
    # ADR-85 WD3 — resolves a {DefHandle} (stored in a bundle-rebuilt discovery table) to a live
    # `Prism::DefNode`, through a per-run parse memo that yields ONE stable node object per `(path, node_id)`
    # per run. Identity stability is a correctness constraint, not an optimisation: the ADR-84 return memo keys
    # on the resolved def-node's object identity, so a fresh parse per resolution would mint a new identity
    # each time and fragment that memo. The memo parses each demanded file at most once (recon Q5: an
    # incremental recheck demands 0–6 files' bodies), builds a `node_id → DefNode` index over its DefNodes, and
    # returns the same object on every later lookup.
    #
    # `node_id` is the primary key; `name` is a cross-check. A miss (the node_id is absent, or its node's name
    # differs — a bundle/source skew the digest gate should make impossible, since identical bytes under the
    # same Prism yield identical node_ids) falls back to the first same-named DefNode in a fresh walk of the
    # file, and finally nil — conservative (the accessor then reports no user def, losing precision but never
    # firing a wrong diagnostic), never silent.
    #
    # The memo is a thread-local installed for the duration of a run (the {Cache::FileDigest} pattern:
    # process-local, Ractor-safe, never crosses a fork boundary, reset per run). Outside a run scope every
    # resolution parses directly — a correct if un-memoised fallback for runner-less probes.
    module DefNodeResolver
      MEMO_KEY = :rigor_def_node_resolver_memo
      private_constant :MEMO_KEY

      # Installs a fresh per-run resolution memo, restoring the previous one on exit (always, even on a raise).
      # `nodes` caches the resolved node per `(path, node_id)`; `indexes` caches each file's parse index;
      # `nestings` re-attaches each handle's recorded `Module.nesting` to the node this module minted for it
      # ({.rehydrated_nesting}).
      def self.with_run
        previous = Thread.current[MEMO_KEY]
        Thread.current[MEMO_KEY] = { nodes: {}, indexes: {}, nestings: {}.compare_by_identity }
        yield
      ensure
        Thread.current[MEMO_KEY] = previous
      end

      # Whether a per-run memo scope is in force. The rehydrated `Module.nesting` ({.rehydrated_nesting}) is
      # recorded only inside one, so this names the precondition the internal spec's "within the resolver's
      # per-run memo scope" clause states — and lets a spec assert that no handle-consuming entry point
      # resolves outside it, which is the difference between the peel fallback being a documented edge and
      # being silently reachable from production.
      def self.run_scope? = !Thread.current[MEMO_KEY].nil?

      # Resolves `handle` to a `Prism::DefNode` (the same object across the run for a given (path, node_id)), or
      # nil. A non-handle argument is returned unchanged, so callers can pass a table value that is either a live
      # node (cold / re-walked file) or a handle (unchanged file) without branching.
      def self.resolve(handle)
        return handle unless handle.is_a?(DefHandle)

        memo = Thread.current[MEMO_KEY]
        return locate(handle, {}) if memo.nil?

        key = [handle.path, handle.node_id].freeze
        nodes = memo[:nodes]
        return nodes[key] if nodes.key?(key)

        node = nodes[key] = locate(handle, memo[:indexes])
        record_nesting(memo, node, handle.nesting)
        node
      end

      # Issue #707 — the recorded `Module.nesting` for a node this module minted from a {DefHandle}, or nil.
      #
      # This is a REHYDRATION of `Scope::DiscoveryIndex#discovered_def_nestings`, not a rival source for the
      # same question, and the single reader ({Inference::ExpressionTyper#recorded_def_nesting}) may consult
      # the table first and fall through here without shadowing a live answer. Two independent facts license
      # that order, and the tempting third one is FALSE:
      #
      # 1. OBJECT PROVENANCE — no node can be a key in both. {.build_file_index} runs its OWN `Prism.parse`,
      #    and both tables are `compare_by_identity`, so a node this module mints is never the object any
      #    walk over the analyzer's own parse produced. This holds per NODE and needs nothing about files.
      # 2. AGREEMENT — where both tables answer for the same DEF (through different objects), they answer the
      #    same chain. A bundle is only reused when the file's content SHA-256 matches
      #    ({Cache::FileDigest.hexdigest}, the digest tier, not the stat one), and `build_def_nestings` is a
      #    pure function of that file's AST, so identical bytes yield an identical chain.
      #
      # What is NOT true — and was asserted here before it was measured — is that a file takes exactly ONE of
      # the two branches per run. It does so in the cross-file pre-pass only. An UNCHANGED file re-analysed as
      # a dependent is served from its bundle there AND walked live by `ScopeIndexer#merge_def_node_tables`
      # for its own per-file index, contributing keys to both tables in one `Runner#run`. Fact 1 is what makes
      # that harmless, so a future change must preserve the separate parse, not the file-level split.
      #
      # `--verify-incremental` is the standing detector for the whole property: it compares the warm and cold
      # diagnostics project-wide, so a disagreement surfaces as a reported incremental-only / full-only
      # diagnostic rather than as a silently preferred answer.
      #
      # Outside a run scope ({.with_run} never entered) nothing is recorded and the reader keeps
      # `Reflection.lexical_nesting_chain`'s peel fallback — the same gradual answer that path already gives.
      # Every entry point that CONSUMES a handle runs inside `with_run`; `spec/rigor/inference/
      # def_node_resolver_spec.rb` pins that, so a new one added outside a run scope fails there rather than
      # silently reverting to the peel.
      def self.rehydrated_nesting(node)
        memo = Thread.current[MEMO_KEY]
        memo && memo[:nestings][node]
      end

      # Files the chain the bundle recorded against the node just minted for it. Issue #716 — an EMPTY chain
      # is recorded like any other: it is the bundle saying the def is written at the top level, and dropping
      # it would leave the warm path peeling the caller's namespace where a cold run resolves at the top
      # level. Only `nil` — a bundle that recorded nothing for the def — is skipped, and
      # `Cache::IncrementalSnapshot::SCHEMA` 17 is what keeps a pre-#716 blob (where `nil` MEANT top level)
      # from being read as one.
      def self.record_nesting(memo, node, nesting)
        return if node.nil? || nesting.nil?

        memo[:nestings][node] = nesting
      end
      private_class_method :record_nesting

      # Finds the node for `handle` using a per-file `{node_id => DefNode}` + `{name => DefNode}` index cache.
      def self.locate(handle, index_cache)
        index = index_cache[handle.path] ||= build_file_index(handle.path)
        node = index[:by_id][handle.node_id]
        return node if node && node.name.to_s == handle.name

        index[:by_name][handle.name]
      rescue StandardError
        nil
      end
      private_class_method :locate

      def self.build_file_index(path)
        root = Prism.parse(File.read(path)).value
        by_id = {}
        by_name = {}
        collect_def_nodes(root, by_id, by_name)
        { by_id: by_id, by_name: by_name }
      end
      private_class_method :build_file_index

      # Walks the tree once, indexing every DefNode by node_id (primary) and by name (first-wins fallback).
      def self.collect_def_nodes(node, by_id, by_name)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::DefNode)
          by_id[node.node_id] = node
          by_name[node.name.to_s] ||= node
        end
        node.rigor_each_child { |child| collect_def_nodes(child, by_id, by_name) }
      end
      private_class_method :collect_def_nodes
    end
  end
end
