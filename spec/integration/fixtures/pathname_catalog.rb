require "pathname"
require "rigor/testing"
include Rigor::Testing

# v0.0.7 — Pathname delegation. The v0.0.6 catalog import
# wired receiver-class recognition for `Pathname.new(...)`;
# v0.0.7 adds:
#
# 1. `Pathname` to `Type::Constant::SCALAR_CLASSES`, so
#    `Pathname.new(Constant<String>)` lifts via `meta_new`'s
#    constant-constructor table to a `Constant<Pathname>`
#    carrier.
# 2. A curated set of pure path-manipulation methods on
#    `Constant<Pathname>` receivers folds through dedicated
#    `try_fold_pathname_unary` / `try_fold_pathname_binary`
#    arms in `MethodDispatcher::ConstantFolding`. These bypass
#    the catalog's `:dispatch` classification (the Pathname
#    Ruby prelude routes most methods through File / Dir, so
#    static catalog purity says "dispatch") and fold directly
#    via the host Ruby Pathname implementation.
# 3. Filesystem-touching methods (`exist?`, `file?`, `read`,
#    …) are intentionally NOT folded — they depend on the
#    analysis machine's filesystem, which is neither stable
#    nor relevant to the analyzed program.

p1 = Pathname.new("/usr/bin/ruby")
assert_type("#<Pathname:/usr/bin/ruby>", p1)

# Pure path-manipulation unary folds.
assert_type("#<Pathname:ruby>", p1.basename)
assert_type("#<Pathname:/usr/bin>", p1.dirname)
assert_type('""', p1.extname)
assert_type('"/usr/bin/ruby"', p1.to_s)
assert_type("true", p1.absolute?)
assert_type("false", p1.relative?)

# Pure path-manipulation binary folds.
assert_type("#<Pathname:/usr/bin/ruby/lib>", p1 + "lib")
assert_type("#<Pathname:/usr/bin/ruby.rbx>", p1.sub_ext(".rbx"))
assert_type("#<Pathname:/usr/bin>", p1.join(".."))

# Comparable folds.
assert_type("0", p1 <=> Pathname.new("/usr/bin/ruby"))
assert_type("true", p1 == Pathname.new("/usr/bin/ruby"))

# Filesystem-dependent calls are NOT folded — the catalog tier
# declines and the answer flows through RBS dispatch on the
# `Constant<Pathname>` receiver. The `nominal_for_name`
# fallback path resolves them to the RBS-declared return type.
exists = p1.exist?
assert_type("false | true", exists)
