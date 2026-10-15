# frozen_string_literal: true

# Issue #1495 — a `case` without a subject tests each `when` condition for truthiness, in order, and stops at the
# first truthy one, so it narrows as the `if` / `elsif` chain it is: a clause's body under the join of its conditions'
# truthy edges, each condition under the falsey edges of the conditions before it, and the next clause and the `else`
# under the last falsey edge. Each comment gives what Ruby 4.0.5 answers.

# `bare_case(nil)` returns 1, `bare_case("a")` "A".
def bare_case(raw)
  x = raw ? String(raw) : nil
  case
  when x.nil? then 1
  else x.upcase
  end
end

# `truthy_condition("a")` returns "A", `truthy_condition(nil)` nil.
def truthy_condition(raw)
  x = raw ? String(raw) : nil
  case
  when x
    assert_type("String", x)
    x.upcase
  end
end

# The body runs when either condition holds, so neither local is narrowed there; the `else` runs only when both are
# false. `multiple_conditions("a", "b")` returns "AB", `multiple_conditions(nil, "b")` :one.
def multiple_conditions(raw_a, raw_b)
  a = raw_a ? String(raw_a) : nil
  b = raw_b ? String(raw_b) : nil
  case
  when a.nil?, b.nil?
    assert_type("String?", a)
    assert_type("String?", b)
    :one
  else a.upcase + b.upcase
  end
end

# The second condition of a clause runs only when the first is false: `second_condition(nil)` returns :short.
def second_condition(raw)
  x = raw ? String(raw) : nil
  case
  when x.nil?, x.empty? then :short
  else x.upcase
  end
end

# A later clause's conditions run under every earlier clause's falsey edge. `later_clause(nil)` returns 1,
# `later_clause("")` 2.
def later_clause(raw)
  x = raw ? String(raw) : nil
  case
  when x.nil? then 1
  when x.empty? then 2
  else x.upcase
  end
end

# `match_condition("k=v")` returns "K".
def match_condition(line)
  case
  when line =~ /(\w+)=/
    assert_type("String", $1)
    $1.upcase
  end
end

# A regexp literal with no subject is tested for its truthiness and matches nothing, so `$1` keeps what it held
# (issue #1486): `"zz" =~ /(z)/; case; when /(b)/ then $1 end` answers "z", and nil before any match.
def bare_regexp_condition
  case
  when /(b)/ then assert_type("String?", $1)
  end
end

# A splat condition holds when any element is truthy, which narrows nothing. `splat_condition([nil, 1], nil)` returns
# nil.
def splat_condition(conditions, raw)
  x = raw ? String(raw) : nil
  case
  when *conditions then assert_type("String?", x)
  end
end

# A local a condition writes is bound on both edges. `condition_write(nil)` returns nil.
def condition_write(raw)
  case
  when (y = raw ? String(raw) : nil) then y.upcase
  else assert_type("nil", y)
  end
end

# The value of a `case` agrees with its statement form wherever it is written. `value_positions(nil)` returns
# ["n", ["n"], "n"].
def value_positions(raw)
  x = raw ? String(raw) : nil
  y = case
      when x.nil? then "n"
      else x
      end
  assert_type('"n" | String', y)
  z = [case
       when x.nil? then "n"
       else x
       end]
  assert_type('["n" | String]', z)
  [y, z, (case
          when x.nil? then "n"
          else x.downcase
          end)]
end

# `nested(nil, nil)` returns 0, `nested("ab", nil)` 2.
def nested(raw_a, raw_b)
  a = raw_a ? String(raw_a) : nil
  b = raw_b ? String(raw_b) : nil
  case
  when a.nil? then 0
  else
    case
    when b.nil? then a.size
    else a.size + b.size
    end
  end
end

# A clause body in a block and a loop. `in_block_and_loop(["q", nil], nil)` returns nil.
def in_block_and_loop(items, raw)
  x = raw ? String(raw) : nil
  items.each do |item|
    case
    when x.nil? then next
    when item.nil? then x.upcase
    else x.upcase + item.to_s
    end
  end
  while items.empty?
    case
    when x.nil? then break
    else x.upcase
    end
  end
end

# A named-capture `=~` rebinds the match globals on both edges, so a clause after an `=~` clause does not read `$1`
# as the `nil` the earlier clause's falsey edge bound, in a value position the evaluator does not enter (an array
# element, a call argument) as in a statement. Each returns "A" (or ["A"]) for "a".
def named_capture_after_match(line)
  [case
   when line =~ /x(\w)/ then 1
   when /(?<nm>a)/ =~ line then $1.upcase
   end]
end

def named_capture_after_match_argument(line)
  Array(case
        when line =~ /x(\w)/ then 1
        when /(?<nm>a)/ =~ line then $1.upcase
        end)
end

def named_capture_after_match_elsif(line)
  [if line =~ /x(\w)/ then 1
   elsif /(?<nm>a)/ =~ line then $1.upcase
   end]
end

def named_capture_after_match_statement(line)
  case
  when line =~ /x(\w)/ then 1
  when /(?<nm>a)/ =~ line then $1.upcase
  end
end

# A local a condition writes in such a value position is not narrowed by an earlier condition the write replaced.
# `compound_write_in_value(nil)` returns ["D"], `write_after_guard_in_value(nil)` ["S"].
def compound_write_in_value(raw)
  x = raw ? String(raw) : nil
  [case
   when (x ||= "d").empty? then 0
   else x.upcase
   end]
end

def write_after_guard_in_value(raw)
  x = raw ? String(raw) : nil
  [case
   when x then 0
   when (x = "s").empty? then 1
   else x.upcase
   end]
end

# A condition that writes a local already bound narrows the value it writes, not the local's old type. With
# `raw = true` and `s = "a"`, each returns "A" (or ["A"]).
def write_over_bound_local(raw, s)
  x = raw ? 1 : nil
  [case
   when (x = s ? String(s) : nil) then x.upcase
   end]
end

def write_over_bound_local_nil_check(raw, s)
  x = raw ? 1 : nil
  [case
   when (x = s ? String(s) : nil).nil? then 0
   else x.upcase
   end]
end

def write_over_bound_local_negated(raw, s)
  x = raw ? 1 : nil
  Array(case
        when !(x = s ? String(s) : nil) then 0
        else x.upcase
        end)
end

# Control: the write's own `nil` still reaches the clause, where Ruby raises NoMethodError.
def write_nil_over_bound_local(raw)
  x = raw ? 1 : nil
  [case
   when (x = nil).nil? then x.upcase # GENUINE-UNDEFINED
   end]
end

# Control: a condition that does not rule out `nil` narrows nothing, so the possible `nil` receiver is reported.
def unguarded(raw)
  x = raw ? String(raw) : nil
  case
  when x.empty? then 1 # GENUINE-NIL
  end
end
