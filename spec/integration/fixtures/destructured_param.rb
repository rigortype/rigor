require "rigor/testing"
include Rigor::Testing

# A destructured positional parameter — `def f((a, b))` — is a
# `Prism::MultiTargetNode` in the parameter list, not a
# `RequiredParameterNode`. The binder must bind each leaf sub-target
# local into the method's entry scope (defaulting to `Dynamic[top]`)
# rather than crashing on a blind `.name`. The canonical real-world
# site is CRuby's erb.rb `def location=((filename, lineno))`.
#
# This fixture exercises a destructured slot mixed with a plain
# positional, a nested destructure, and a splat sub-target. The mere
# absence of an `internal analyzer error` (asserted by the spec via
# `errors`) is the regression guard; the destructured locals also read
# back as `Dynamic[top]` rather than falling through to undefined-local
# noise.
def location=((filename, lineno))
  filename
  lineno
end

def combine(_prefix, (_a, (_b, _c)), (_d, *_e, f))
  f
end
