# frozen_string_literal: true

# ADR-116 WD5 — the entry point for {Rigor::Inference::DeclarationWalk}. The walk lives in
# `declaration_walk/traversal`, and the context rules it applies are `ScopeIndexer` functions, so this file loads
# the indexer, which loads the walk. `ScopeIndexer` itself requires the traversal file rather than this one, which
# keeps the two free of a require cycle.
require_relative "scope_indexer"
