# frozen_string_literal: true

# ADR-116 WD5 — the entry point for {Rigor::Inference::DeclarationWalk}. The walk lives in
# `declaration_walk/traversal` and the context rules it applies in `declaration_walk/rules` (ADR-116 WD9). The
# indexer loads both, the rules last of the files its head requires so that their slot keeps its place in
# `TypingState.slots`, so this file loads the indexer. `ScopeIndexer` itself requires those two files rather than
# this one, which keeps them free of a require cycle.
require_relative "scope_indexer"

# {Rigor::Reflection.class_declarations_in}'s collectors: the plugin-facing walk lives with `Reflection` but needs the
# walk above, so it is loaded here rather than by `reflection/declarations`, which the engine-free paths load.
require_relative "../reflection/declaration_collectors"
