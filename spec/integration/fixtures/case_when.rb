require "rigor/testing"
include Rigor::Testing

# `case/when` over an integer subject constructs a precise
# Symbol-literal union from the branch results — one slot per
# `when` arm (plus `else`).
n = 0
label = case n
        when 0 then :zero
        when 1..9 then :small
        else :large
        end
assert_type(":large | :small | :zero", label)
