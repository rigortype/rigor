# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Struct` catalog. Singleton — load once, consult during
      # dispatch.
      #
      # `Struct` is a meta-class: `Struct.new(*members)` returns a
      # fresh anonymous subclass — never a `Struct` value. Today
      # Rigor never produces a `Constant<Struct>` carrier (a literal
      # struct instance), so the catalog is defensive: it documents
      # the shape and forbids unsafe folds in case a future tier
      # learns to lift literal struct instances into the value
      # lattice.
      #
      # Subclasses define their own writers (`name=`) at class-build
      # time, so per-instance member accessors do not appear in this
      # YAML — only the generic `[]` / `[]=` pair on the base class.
      # `[]=` is already classified `:mutates_self`; `[]` reads a
      # member but the answer depends on the subclass's member
      # definition, which the catalog does not see, so we blocklist
      # it defensively.
      STRUCT_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/struct.yml",
          __dir__
        ),
        mutating_selectors: {
          "Struct" => Set[
            # Defensive: aliasing-copy semantics on a hypothetical
            # `Constant<Struct>` carrier. Convention across the
            # other catalogs (Range, Random, Pathname).
            :initialize_copy,
            # `rb_struct_hash` mixes member values via
            # `rb_hash` -> `rb_funcall(:hash, ...)`. The classifier
            # sees no direct dispatch because the recursion goes
            # through `rb_hash` (a helper), but the answer depends
            # on the member values' `#hash` — user-redefinable.
            # Block to avoid folding a hash that would diverge
            # from the runtime once a member overrides `#hash`.
            :hash,
            # `rb_struct_aref` reads a member by name or index; the
            # answer depends on the subclass's member layout, which
            # the catalog does not carry. Folding without knowing
            # the layout would be unsound.
            :[]
          ]
        }
      )
    end
  end
end
