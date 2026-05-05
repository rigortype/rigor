require "rigor/testing"
include Rigor::Testing

# Regexp / MatchData catalog import. `Init_Regexp` registers
# both classes in the same C init block, so a single topic
# (`re`) drives both. What the import buys us:
#
# 1. Pure readers on a `Constant<Regexp>` literal fold to
#    concrete answers via the catalog tier (`#source`,
#    `#options`, `#casefold?`, `#fixed_encoding?`, `#inspect`,
#    `#to_s`, `#hash`). The receiver type already lifts to
#    `Constant<Regexp>` for non-interpolated patterns
#    (v0.0.7 — see `ExpressionTyper#type_of_regexp`), so the
#    catalog tier sees a real `Regexp` instance and can run
#    the method directly.
# 2. `Regexp.new(...)` resolves to `Nominal[Regexp]` so
#    downstream method dispatch knows the receiver class —
#    no constant-constructor lift today, the host RBS sigs
#    take it from there.
# 3. The blocklist defends `Regexp#=~`, `Regexp#===`,
#    `Regexp#~`, `Regexp#match`, and `:initialize_copy` on
#    both classes so a constant-fold cannot drop the visible
#    side effect of writing `$~` (the per-thread last-match
#    backref). Folding `/abc/ =~ "xabc"` to `4` would erase
#    the `$1..$N` / `$&` / `` $` `` / `$'` updates that any
#    later code is allowed to read.

# ---------------------------------------------------------------
# Regexp side: Constant<Regexp> readers fold through the catalog.
# ---------------------------------------------------------------

r = /abc/
assert_type("/abc/", r)

# `Regexp#source` is `:leaf`; the catalog runs the actual
# Ruby method on the literal pattern and lifts the answer
# back to `Constant<String>`.
assert_type('"abc"', r.source)

# `Regexp#options` is `:leaf` and returns the bitfield
# (zero for `/abc/` with no flags).
assert_type("0", r.options)

# Pure boolean readers fold the same way.
assert_type("false", r.casefold?)
assert_type("false", r.fixed_encoding?)

# Pretty-printers fold to their `String#inspect`-style answer.
assert_type('"(?-mix:abc)"', r.to_s)
assert_type('"/abc/"', r.inspect)

# Folding a flagged pattern shows that the `options` answer
# really is computed: `i` sets `Regexp::IGNORECASE` (bit 1),
# `m` sets `MULTILINE` (bit 4), so the bitfield reads 5.
flagged = /abc/im
assert_type("5", flagged.options)
assert_type("true", flagged.casefold?)

# ---------------------------------------------------------------
# Regexp.new path: `Nominal[Regexp]` — no constant-constructor
# lift today, the catalog still recognises the receiver class
# so subsequent dispatch flows through the right entry.
# ---------------------------------------------------------------

dyn = Regexp.new("abc")
assert_type("Regexp", dyn)
