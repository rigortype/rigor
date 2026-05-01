# `rigor check` flags `Integer / 0` and friends as always-raising.
# Each of the lines below produces an `:error`-severity diagnostic
# under the `always-raises` rule. `# rigor:disable always-raises`
# silences the rule for that line.

# Direct constant divisor
a = 5 / 0 # rigor:disable always-raises

# Wider receiver, but a literal-zero divisor still proves the
# call always raises.
n = rand(100)
b = n / 0 # rigor:disable always-raises

# Modulo, integer-div, modulo, divmod all raise on zero.
c = 5 % 0 # rigor:disable always-raises
d = 5.div(0) # rigor:disable always-raises
e = 5.modulo(0) # rigor:disable always-raises
f = 5.divmod(0) # rigor:disable always-raises

# Float arithmetic by zero is `Infinity` / `NaN` at runtime — no
# raise — and the rule stays silent.
g = 5.0 / 0
h = 5 / 0.0
i = 5.fdiv(0)
