require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the Time catalog from `Init_Time`
# in `references/ruby/time.c` plus the `references/ruby/timev.rb`
# prelude (compiled into `timev.rbinc` and #include'd at the bottom
# of `time.c`). Time has no Constant-tier carrier today — there is
# no `Time` literal node — so the catalog wiring mostly governs
# the dispatch hop on `Nominal[Time]` receivers and the blocklist
# coverage.

# `Time.now` returns `Nominal[Time]` per RBS. The singleton-side
# entry routes through the catalog (`now` is a `:unknown`-purity
# prelude method, so the fold check bails and the RBS-tier answer
# is preserved) — what the assertion confirms is that the engine
# does not silently produce `Constant<Time>` or any other unsound
# carrier when the singleton-method route is consulted.
t = Time.now
assert_type("Time", t)

# Reader surface — RBS-declared `Integer`. Each of these is
# catalog-classified `:leaf` against a `time_*` cfunc with no
# dispatch / mutation / yield, so a future `Constant<Time>`
# carrier would be eligible to fold them. Today the receiver is
# `Nominal[Time]`, so the answer comes from the RBS tier.
assert_type("Integer", t.year)
assert_type("Integer", t.month)
assert_type("Integer", t.day)
assert_type("Integer", t.hour)
assert_type("Integer", t.min)
assert_type("Integer", t.sec)
assert_type("Integer", t.wday)
assert_type("Integer", t.utc_offset)

# Boolean predicates — RBS-declared `bool` (`false | true`).
assert_type("false | true", t.utc?)
assert_type("false | true", t.sunday?)
assert_type("false | true", t.dst?)

# String-returning leaves. `strftime` and the `iso8601` alias
# (registered as `xmlschema` in Init_Time) both return `String`.
# `xmlschema` is mis-classified `:mutates_self` by the C-body
# regex (the cfunc allocates a temporary buffer that the regex
# mistakes for self-mutation), so the catalog tier rejects it
# even though it is safe; the RBS tier answers with `String`.
assert_type("String", t.strftime("%Y-%m-%d"))

# Mutators / pseudo-mutators are blocklisted so the dispatcher
# never folds them into a Constant. `localtime`, `gmtime`, and
# `utc` all call `time_modify(time)` to mark the receiver
# mutable before rewriting its `vtm` cache — but the C-body
# classifier mis-flags them as `:leaf` (the indirect `time_modify`
# helper is not in the regex's mutator list). The blocklist keeps
# the fold inert; the RBS tier answers with `Nominal[Time]`.
assert_type("Time", t.localtime)
assert_type("Time", t.gmtime)
assert_type("Time", t.utc)

# Non-mutating siblings of the above. `getlocal`, `getgm`, and
# `getutc` return brand-new Time objects without modifying the
# receiver — they stay catalog-eligible (and would fold through
# a future `Constant<Time>` carrier) but are answered by the RBS
# tier today.
assert_type("Time", t.getlocal)
assert_type("Time", t.getutc)
