require "date"
require "rigor/testing"
include Rigor::Testing

# Date / Time Constant carrier + folding (coverage uplift). The
# fixture is project-style so the bundled `date` stdlib RBS is
# visible. Date / DateTime / Time literals only ever arise from
# the deterministic constructors folded below — there is no
# Date / Time literal node.

# `Date.new(y, m, d)` folds to a `Constant[Date]`; `describe`
# renders it in ISO-8601.
assert_type("2026-01-01", Date.new(2026, 1, 1))

# Date readers fold through the catalog: Integer components,
# bool predicates, String formatting.
assert_type("2026", Date.new(2026, 1, 1).year)
assert_type("1", Date.new(2026, 1, 1).month)
assert_type("false", Date.new(2026, 1, 1).leap?)
assert_type("true", Date.new(2024, 1, 1).leap?)
assert_type('"2026/01"', Date.new(2026, 1, 1).strftime("%Y/%m"))

# Non-mutating Date navigation returns a fresh Constant[Date].
assert_type("2026-01-02", Date.new(2026, 1, 1).next_day)
assert_type("2026-02-01", Date.new(2026, 1, 1) >> 1)

# DateTime.new — offset defaults to UTC, so the literal is
# machine-independent.
assert_type("2026-01-01T12:00:00+00:00", DateTime.new(2026, 1, 1, 12))
assert_type("12", DateTime.new(2026, 1, 1, 12).hour)

# `Time.utc` / `Time.gm` pin the result to UTC; `describe` uses
# the compact inspect form.
assert_type("2026-01-01 00:00:00 UTC", Time.utc(2026, 1, 1))
assert_type("2026", Time.utc(2026, 1, 1).year)
assert_type("0", Time.utc(2026, 1, 1).hour)
assert_type("true", Time.utc(2026, 1, 1).utc?)
assert_type("0", Time.utc(2026, 1, 1).utc_offset)
assert_type('"12:30"', Time.utc(2026, 1, 1, 12, 30, 15).strftime("%H:%M"))
assert_type("2026-01-01 01:00:00 UTC", Time.utc(2026, 1, 1) + 3600)

# Non-deterministic constructors are NOT folded — they keep the
# RBS `Nominal` answer.
assert_type("Time", Time.now)
assert_type("Date", Date.today)

# `getlocal` is blocklisted: its result is pinned to the analysis
# machine's timezone, so folding it would bake a host-dependent
# value into the type. The RBS tier answers `Nominal[Time]`.
assert_type("Time", Time.utc(2026, 1, 1).getlocal)
