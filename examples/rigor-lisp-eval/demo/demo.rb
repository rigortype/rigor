# frozen_string_literal: true

require_relative "lib/lisp"

# Each `Lisp.eval(...)` call below produces an `info`
# diagnostic from the rigor-lisp-eval plugin naming the
# statically-inferred return type. Run from this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check demo.rb

# Pure integer arithmetic.
sum = Lisp.eval([:+, 1, [:*, 2, 3]])
puts sum

# Mixed int / float — float wins.
mixed = Lisp.eval([:+, 1, [:*, 2.0, 3]])
puts mixed

# Comparison — boolean.
ordered = Lisp.eval([:<, 1, 2])
puts ordered

# Conditional — branch type union.
maybe = Lisp.eval([:if, [:<, 1, 2], 1, 2.0])
puts maybe

# Boolean composition.
both = Lisp.eval([:and, true, [:not, false]])
puts both

# Non-literal argument — the plugin stays silent rather than
# guessing. The analyzer treats the call as `untyped` per the
# RBS signature.
program = [:+, 1, 2]
unknown = Lisp.eval(program)
puts unknown

# Ill-typed expression — surfaces as an error diagnostic.
# Comment the next line out to silence the type-error path.
broken = Lisp.eval([:+, 1, true])
puts broken
