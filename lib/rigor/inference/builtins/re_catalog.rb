# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Regexp` / `MatchData` catalog. Singleton — load once,
      # consult during dispatch.
      #
      # `Init_Regexp` in `references/ruby/re.c` registers BOTH
      # classes in a single C init block, so the catalog carries
      # both — `Regexp` (the pattern carrier) plus `MatchData`
      # (the result-of-match carrier produced by `Regexp#match` /
      # `String#match` and consulted via `$~`). The catalog wiring
      # therefore mostly governs:
      #
      # 1. The reader surface on each class (`Regexp#source`,
      #    `Regexp#options`, `Regexp#casefold?`, `MatchData#size`,
      #    `MatchData#captures`, etc.) — RBS-declared returns are
      #    preserved through dispatch.
      # 2. The blocklist below, which keeps methods that touch
      #    process-global state (the `$~` backref) from being
      #    folded. Regexp matching is observably stateful:
      #    `Regexp#=~`, `#===` and `#~` all call `rb_backref_set`
      #    (writing `$~` and the `$1..$N` / `$&` / `` $` `` / `$'`
      #    aliases). A constant-fold that dropped those calls
      #    would silently change the visible state of the program,
      #    so they MUST decline through to the RBS tier.
      #
      # `Regexp.last_match` and `Regexp.timeout` / `Regexp.timeout=`
      # are class-level (singleton) methods that also touch
      # process-global state, but the dispatcher's catalog lookup
      # only consults `:instance` entries today — class-method calls
      # on a `Singleton` receiver type take the `meta_*` path in
      # `MethodDispatcher` rather than walking `CATALOG_BY_CLASS` —
      # so listing them here would be dead code. Their RBS-tier
      # signatures already widen the answer enough to keep the
      # behaviour sound; revisit if the dispatcher ever grows a
      # singleton-aware catalog path.
      REGEXP_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/re.yml",
          __dir__
        ),
        mutating_selectors: {
          "Regexp" => Set[
            # Defensive: aliasing-copy semantics already covered
            # by the `:mutates_self` classifier, listed here for
            # symmetry with String / Array / Hash / Range / Set.
            :initialize_copy,
            # `=~`, `===`, `~` all run `rb_reg_search` (or call
            # `rb_backref_set(Qnil)` directly) — every successful
            # OR failing match writes `$~` and the
            # `$1..$N` / `$&` / `` $` `` / `$'` aliases. Folding
            # would discard the visible side effect.
            :=~,
            :"===",
            :~,
            # `match` is already `:block_dependent` (the C body
            # yields), but it ALSO writes `$~` regardless of the
            # block. Listed here so a future extractor that
            # reclassifies it as `:leaf` (because the yield is
            # behind a helper) does not silently fold it.
            :match
          ],
          "MatchData" => Set[
            # Defensive entry mirroring the other catalogs.
            # `match_init_copy` is already `:leaf` per the
            # extractor (it copies the regs slot in place but
            # uses no helper the C-body regex flags as a
            # mutator); blocked so a future
            # `Constant<MatchData>` carrier never folds an
            # aliasing copy through the catalog.
            :initialize_copy
          ]
        }
      )
    end
  end
end
