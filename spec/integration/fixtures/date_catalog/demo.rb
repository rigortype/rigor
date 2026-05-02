require "date"
require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the Date / DateTime catalog from
# `Init_date_core` in `references/ruby/ext/date/date_core.c`. The
# `lib/date.rb` prelude only contributes `Date#infinite?` and the
# nested `Date::Infinity` class — the bulk of the surface is in C.
#
# Date / DateTime have no `Constant`-tier carrier today (there is
# no Date literal node — the closest is `Date.today` /
# `Date.parse(...)`, which produce `Nominal[Date]`), so the catalog
# wiring mostly governs the dispatch hop on `Nominal[Date]` /
# `Nominal[DateTime]` receivers and the blocklist coverage. The
# fixture is project-style (lives under `date_catalog/` and runs
# through `Environment.for_project`) so the bundled `date` stdlib
# RBS signatures are visible.

# `Date.today` / `Date.parse` return `Nominal[Date]` per RBS. The
# singleton-side entries route through the catalog (`today`,
# `parse` are `:leaf`-classified prelude-less cfuncs) — what the
# assertion confirms is that the engine does not silently produce
# `Constant<Date>` or any other unsound carrier.
d = Date.today
assert_type("Date", d)

parsed = Date.parse("2026-05-02")
assert_type("Date", parsed)

# Reader surface — RBS-declared `Integer`. Each is catalog-classified
# `:leaf` against a `d_lite_*` cfunc with no dispatch / mutation /
# yield, so a future `Constant<Date>` carrier would be eligible to
# fold them. Today the receiver is `Nominal[Date]`, so the answer
# comes from the RBS tier.
assert_type("Integer", d.year)
assert_type("Integer", d.month)
assert_type("Integer", d.day)
assert_type("Integer", d.wday)
assert_type("Integer", d.yday)
assert_type("Integer", d.cwyear)
assert_type("Integer", d.cweek)
assert_type("Integer", d.cwday)

# Boolean predicates — RBS-declared `bool` (`false | true`).
assert_type("false | true", d.leap?)
assert_type("false | true", d.julian?)
assert_type("false | true", d.gregorian?)
assert_type("false | true", d.sunday?)

# String-returning leaves. `to_s`, `iso8601`, and `strftime` all
# return `String` per RBS.
assert_type("String", d.to_s)
assert_type("String", d.iso8601)
assert_type("String", d.strftime("%Y-%m-%d"))

# Non-mutating navigation. `next_day`, `prev_day`, `next_month`,
# `next_year`, `succ`, `>>`, `<<` all RETURN brand-new `Date`
# objects rather than mutating the receiver. They stay
# catalog-eligible.
assert_type("Date", d.next_day)
assert_type("Date", d.prev_day)
assert_type("Date", d.next_month)
assert_type("Date", d.prev_year)
assert_type("Date", d.succ)
assert_type("Date", d >> 1)
assert_type("Date", d << 1)

# DateTime is a subclass; its dedicated reader surface adds
# `hour` / `min` / `sec` / `offset` / `zone`. `DateTime.now`
# returns `Nominal[DateTime]` per RBS.
dt = DateTime.now
assert_type("DateTime", dt)
assert_type("Integer", dt.hour)
assert_type("Integer", dt.min)
assert_type("Integer", dt.sec)
assert_type("String", dt.iso8601)
assert_type("String", dt.strftime("%H:%M:%S"))

# Inherited Date readers still answer Integer on a DateTime
# receiver — the catalog routes `DateTime`-receiver lookups
# through the DateTime entry, but inherited `d_lite_year` /
# `d_lite_mon` / `d_lite_mday` are visible via the subclass
# relationship in the YAML's `parent: Date` chain.
assert_type("Integer", dt.year)
assert_type("Integer", dt.month)
assert_type("Integer", dt.day)
