require "rigor/testing"
include Rigor::Testing

# Predicate-subset half of the OQ3 refinement-carrier strategy
# (docs/adr/3-type-representation.md). The annotation tightens
# `Username#slug`'s RBS-declared `String` return to the
# `lowercase-string` refinement; call sites see the precise
# carrier without a runtime check, the engine projects the
# case-normalisation pair through `Refined[String, :lowercase]`,
# and RBS erasure folds the carrier back to `String`.
#
#   class Username
#     %a{rigor:v1:return: lowercase-string}
#     def slug: () -> String
#     ...
#   end
class Username
  def slug
    "alice"
  end

  def shout
    "ALICE"
  end

  def code
    "42"
  end

  def decimal_id
    "1024"
  end

  def octal_mode
    "0o755"
  end

  def hex_color
    "0xff"
  end
end

user = Username.new

s = user.slug
assert_type("lowercase-string", s)
# `String#downcase` over a lowercase-string is idempotent so the
# carrier survives.
assert_type("lowercase-string", s.downcase)
# `String#upcase` lifts a lowercase-string to an uppercase-string.
assert_type("uppercase-string", s.upcase)
# Size-tier projections still apply through the predicate carrier.
assert_type("non-negative-int", s.size)

t = user.shout
assert_type("uppercase-string", t)
assert_type("uppercase-string", t.upcase)
assert_type("lowercase-string", t.downcase)

n = user.code
assert_type("numeric-string", n)
# `numeric-string` is the full Ruby numeric-literal grammar, so
# `#downcase` preserves it (lowercasing a literal — hex digits,
# `0X`/`E` prefixes — is always still a valid literal) but
# `#upcase` does NOT: the rational / imaginary suffixes are
# lowercase-only (`"1r".upcase == "1R"` is not a literal), so the
# refinement is soundly dropped to `String`.
assert_type("numeric-string", n.downcase)
assert_type("String", n.upcase)

# The base-N int-string predicate refinements are case-invariant
# under the case-fold pair: digit-only strings are unchanged and
# the `0o` / `0x` prefix letters round-trip through the predicate
# in either case.
d = user.decimal_id
assert_type("decimal-int-string", d)
assert_type("decimal-int-string", d.downcase)
assert_type("decimal-int-string", d.upcase)
# `#to_i` parses to a plain (possibly signed) Integer, NOT
# non-negative-int: the decimal-int-string predicate `/\A-?\d+\z/`
# admits a leading sign, so a `"-7"` inhabitant yields `-7`. The
# carrier is the full `int` range (`universal_int`), keeping the
# narrowing sound while still handing downstream a range to refine.
di = d.to_i
assert_type("int", di)

o = user.octal_mode
assert_type("octal-int-string", o)
assert_type("octal-int-string", o.downcase)
assert_type("octal-int-string", o.upcase)

h = user.hex_color
assert_type("hex-int-string", h)
assert_type("hex-int-string", h.downcase)
assert_type("hex-int-string", h.upcase)
