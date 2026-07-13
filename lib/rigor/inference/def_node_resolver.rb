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
      # `nodes` caches the resolved node per `(path, node_id)`; `indexes` caches each file's parse index.
      def self.with_run
        previous = Thread.current[MEMO_KEY]
        Thread.current[MEMO_KEY] = { nodes: {}, indexes: {} }
        yield
      ensure
        Thread.current[MEMO_KEY] = previous
      end

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

        nodes[key] = locate(handle, memo[:indexes])
      end

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
