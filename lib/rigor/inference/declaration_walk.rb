# frozen_string_literal: true

# ADR-116 WD5 — the entry point for {Rigor::Inference::DeclarationWalk}. The walk lives in
# `declaration_walk/traversal`, and the context rules it applies are `ScopeIndexer` functions, so this file loads
# the indexer, which loads the walk. `ScopeIndexer` itself requires the traversal file rather than this one, which
# keeps the two free of a require cycle.
require_relative "scope_indexer"

# {Rigor::Reflection.class_declarations_in}'s collectors: the plugin-facing walk lives with `Reflection` but needs the
# walk above, so it is loaded here rather than by `reflection/declarations`, which the engine-free paths load.
require_relative "../reflection/declaration_collectors"
