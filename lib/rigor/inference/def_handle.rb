# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-85 WD3 — a lazy reference to a `Prism::DefNode` stored in a cross-file discovery table, in place of
    # the live node itself. When an incremental recheck rebuilds the discovery index from cached per-file seed
    # bundles (ADR-85 WD2), the `def_nodes` / `singleton_def_nodes` tables carry handles for every unchanged
    # file's methods: the file was never parsed this run, so there is no live node to store. A handle records
    # the four things needed to resolve, fingerprint, or scope it without the node:
    #
    # - `path` + `node_id` — the resolution key. The per-run parse memo ({Scope#resolve_def_handle}) parses the
    #   file once and returns the `Prism::DefNode` whose `node_id` matches (Prism `node_id` is stable across
    #   repeated parses of identical bytes). `name` is the cross-check: a resolved node whose `name` differs
    #   from the handle's forces a fresh walk (bundle/source skew that the digest gate should make impossible —
    #   conservative, never silent).
    # - `fingerprint` — the SHA-256 of the def's source slice, captured when the bundle was built. This lets
    #   `Runner#symbol_fingerprints` read the change-detection fingerprint (ADR-46 slice 4) off the handle
    #   without re-parsing the file — the one value-deref consumer besides the three accessor choke points.
    # - `nesting` — the `Module.nesting` in force where the def is WRITTEN (issue #681's chain), or nil for a
    #   top-level def, which records none. The cross-file `def_nestings` table is keyed by node IDENTITY, and
    #   {DefNodeResolver} hands back a node from its OWN parse, so no identity-keyed table built by the
    #   discovery walk can ever contain it. Travelling on the handle is what lets the resolver re-attach the
    #   chain to the node it mints, instead of the re-walk falling back to peeling the receiver's qualified
    #   name — which cannot tell a compact `class Admin::Maker` from the nested spelling, so an unchanged
    #   file's callee answered a different constant on the warm path than on a cold run ([#707]).
    #
    # A required member rather than a defaulted one: a writer that has a chain and forgets to pass it
    # reintroduces exactly the divergence above, silently, so the constructor is where that must fail loudly.
    #
    # Marshal-clean by construction (Integer + Strings + a String array), so it rides the
    # `IncrementalSnapshot` blob directly.
    DefHandle = Data.define(:path, :node_id, :name, :fingerprint, :nesting)
  end
end
