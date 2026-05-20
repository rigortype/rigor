require "rigor/testing"
include Rigor::Testing

# ADR-24 WD6, extended to `eval_and_or` — a divergent guard
# helper on the RHS of `or` narrows the LHS. `fail_now` always
# raises, so `x = src or fail_now` survives only on the edge
# where `src` returned its non-nil fragment. Before this change
# `eval_and_or` recognised only the syntactic exit calls
# (`raise` / `return` / `throw` / `exit` / `abort` / `fail` /
# `next` / `break`), so a resolved guard helper on the RHS did
# not narrow; now a `Bot`-typed RHS is treated as a terminating
# branch exactly as in `eval_if` / `eval_unless`.
def src
  rand < 0.5 ? "x" : nil
end

def fail_now
  raise "no"
end

x = src or fail_now
assert_type('"x"', x)
x
