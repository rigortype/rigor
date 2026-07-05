# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Numeric` family catalog (Integer, Float, Rational, Complex, Numeric). Singleton — load once,
      # consult during dispatch.
      #
      # The catalog is produced offline by `tool/extract_builtin_catalog.rb` from the CRuby reference
      # checkout under `references/ruby` plus the RBS core signatures under `references/rbs`. The loader
      # is the runtime bridge: callers ask "is `Integer#+` safe to invoke during constant folding?" and
      # the answer comes straight from the offline classification (`leaf` / `trivial` / `leaf_when_numeric`
      # are foldable; everything else is not).
      #
      # No mutation blocklist is needed. The numeric classes expose no foldable bang or indirect-mutator
      # method that the static C classifier mis-attributes (every `:leaf` numeric method is a pure value
      # computation), so the generic `MethodCatalog` loader — shared with the eighteen other per-class
      # catalogs — covers it directly. This previously hand-rolled its own `safe_for_folding?` /
      # `method_entry` / `load_catalog` copy of `MethodCatalog`; folding it onto the shared loader also
      # picks up alias resolution (e.g. `Integer#magnitude` → `abs`, `Integer#inspect` → `to_s`), which the
      # old bespoke loader silently dropped.
      NUMERIC_CATALOG = MethodCatalog.for_topic("numeric")
    end
  end
end
