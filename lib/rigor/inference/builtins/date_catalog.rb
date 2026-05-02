# frozen_string_literal: true

# `Date` and `DateTime` live in CRuby's bundled `date` gem, which
# is stdlib rather than core — so the constants are not visible
# until `date` is required. The dispatcher's `CATALOG_BY_CLASS`
# table references `Date` and `DateTime` at load time, so requiring
# the gem here (alongside the loader file that exports the catalog)
# keeps the wiring self-contained: a consumer that pulls in the
# constant-folding rule book gets the Date constants for free.
require "date"

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Date` / `DateTime` catalog. Singleton — load once, consult
      # during dispatch.
      #
      # `Date` and `DateTime` both come from CRuby's bundled `date`
      # gem (`references/ruby/ext/date/date_core.c`). A single
      # `Init_date_core` function registers them, so the catalog
      # carries both classes — `Date` plus the `DateTime` subclass
      # whose own Init block extends with `hour` / `min` /
      # `strftime` / `iso8601` etc. The Ruby-side prelude
      # (`lib/date.rb`) only contributes `Date#infinite?` and the
      # nested `Date::Infinity` class; the bulk of the surface is
      # in C.
      #
      # Date / DateTime receivers are not lifted to a `Constant`
      # carrier today (there is no Date literal node — the closest
      # is `Date.today` / `Date.parse(...)`, which produce
      # `Nominal[Date]`). The catalog wiring therefore mostly
      # governs:
      #
      # 1. The Integer-typed reader surface (`#year`, `#month`,
      #    `#day`, `#wday`, `#hour`, `#min`, `#sec`) — RBS-declared
      #    `Integer` is preserved through dispatch.
      # 2. The blocklist below, which keeps mutator-style methods
      #    that the C-body classifier already flagged
      #    (`mutates_self`) from being missed by a future
      #    `Constant<Date>` carrier, plus a defensive
      #    `:initialize_copy` entry for symmetry with the other
      #    catalogs.
      #
      # The non-bang `#next_day` / `#prev_day` / `#next_month` /
      # `#prev_month` / `#next_year` / `#prev_year` / `#>>` / `#<<`
      # selectors all RETURN brand-new `Date` objects rather than
      # mutating the receiver — they intentionally stay
      # catalog-eligible. The two real mutators
      # (`#initialize_copy`, `#marshal_load`) are already classified
      # `:mutates_self` by the C-body regex, so they fall out of
      # `MethodCatalog#safe_for_folding?` without an explicit
      # blocklist entry; the entries below are defense-in-depth
      # against indirect mutators the regex might miss in a future
      # CRuby bump.
      DATE_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/date.yml",
          __dir__
        ),
        mutating_selectors: {
          "Date" => Set[
            # `d_lite_initialize_copy` is already classed
            # `:mutates_self` by the regex (it calls
            # `rb_check_frozen` and rewrites the receiver's
            # internal `dat` slots). Listed here for symmetry with
            # String / Array / Range / Set / Time and to keep the
            # blocklist self-documenting.
            :initialize_copy,
            # `d_lite_fill` is a `#ifndef NDEBUG` debug method that
            # warms the receiver's cached `simple` / `complex`
            # fields via the `get_s_*` / `get_c_*` macros. The
            # macros perform in-place writes on the receiver's
            # internal `dat` struct but use no helper the C-body
            # regex recognises, so the classifier mis-flags it
            # `:leaf`. Blocked so a future `Constant<Date>` carrier
            # never folds it.
            :fill
          ],
          "DateTime" => Set[
            # `DateTime` inherits the bulk of its surface from
            # `Date`. The dedicated DateTime-side methods are all
            # readers (`hour`, `min`, …) plus formatting
            # converters (`strftime`, `iso8601`, …); none mutate
            # the receiver. The single defensive entry mirrors the
            # Date side so that the inherited
            # `Date#initialize_copy` (registered against
            # `cDateTime` through subclassing) cannot fold through
            # the catalog if a future `Constant<DateTime>` carrier
            # ever lands.
            :initialize_copy
          ]
        }
      )
    end
  end
end
