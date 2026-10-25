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
      # computation), so the generic `MethodCatalog` loader covers it directly. Using the shared loader
      # rather than a bespoke copy also gives it alias resolution (e.g. `Integer#magnitude` → `abs`).
      NUMERIC_CATALOG = MethodCatalog.for_topic("numeric")
    end
  end
end
