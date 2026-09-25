# rubocop:disable Style/PerlBackrefs
require "rigor/testing"
include Rigor::Testing

s = "abc123"

# Truthy =~ edge: unconditional group 1 narrows to String.
assert_type("String", $1) if /(\d+)/ =~ s

# $~ narrows to MatchData on the match edge.
assert_type("MatchData", $~) if /(\d+)/ =~ s

# $& narrows to String on the match edge.
assert_type("String", $&) if /(\d+)/ =~ s

# Receiver order swapped narrows identically.
assert_type("String", $1) if s =~ /(\d+)/

# Optional group stays nilable even on the match edge.
assert_type("String?", $1) if /x(y)?/ =~ s

# Alternation disqualifies group promotion.
assert_type("String?", $1) if /(a)|(b)/ =~ s

# No-match edge: every global is nil.
assert_type("nil", $1) unless /(\d+)/ =~ s
assert_type("nil", $~) unless /(\d+)/ =~ s

# match? does NOT set globals.
assert_type("String?", $1) if s.match?(/(z)/)

# case/when /re/ body edge narrows like the =~ truthy edge.
case s
when /a(b)c/
  assert_type("String", $1)
end
case s
when /(p)(q)?/
  assert_type("String?", $2)
end

# Regexp.last_match(N) mirrors $N narrowing on a proven-match edge.
# Both groups unconditional: last_match(N) -> String.
# Assign to locals before assert_type so the implicit-self call
# does not trigger forget_match_globals between the two checks.
if /([a-z]+)(\d+)/ =~ s
  lm1 = Regexp.last_match(1)
  lm2 = Regexp.last_match(2)
  assert_type("String", lm1)
  assert_type("String", lm2)
end
# Optional group: last_match(N) -> String?.
if /([a-z]+)(\d+)?/ =~ s
  lm1_uncond = Regexp.last_match(1)
  lm2_opt    = Regexp.last_match(2)
  assert_type("String", lm1_uncond)
  assert_type("String?", lm2_opt)
end
# Optional group via alternation: last_match(N) -> String?.
assert_type("String?", Regexp.last_match(1)) if /(a)|(b)/ =~ s
# Off-edge (no proven match): last_match(N) defers to RBS -> String?.
assert_type("String?", Regexp.last_match(1))

# Issue #1358 — the match globals live in the method frame's special-variable slot, which the method's blocks and
# closures share, so a match a block or closure runs rebinds the enclosing method's `$~`. Each case is a method, so
# a closure's frame is that method's rather than this file's top level.

# A block whose body matches rebinds `$~` (Ruby: `block_match("a1", ["q"])` returns nil).
def block_match(str, items)
  if str =~ /(\d+)/
    items.each { |i| i =~ /(zzz)/ }
    group = $1
    no_match = $~.nil?
    assert_type("String?", group)
    assert_type("bool", no_match)
  end
end

# Control: a block with no match in its body keeps the narrowing.
def block_without_match(str, items)
  if str =~ /(\d+)/
    items.each { |i| puts i }
    group = $1
    no_match = $~.nil?
    assert_type("String", group)
    assert_type("false", no_match)
  end
end

# Control: a match inside a nested `def` runs in that method's own frame.
def block_with_nested_def(str, items)
  if str =~ /(\d+)/
    items.each { |_i| def nested_matcher(x) = (x =~ /(q)/) }
    assert_type("String", $1)
  end
end

# A `when /re/` condition runs `Regexp#===`, which rebinds `$~` as well.
def block_case_when(str, items)
  if str =~ /(\d+)/
    items.each { |i| case i when /(z)/ then i end }
    assert_type("String?", $1)
  end
end

# A read before the body's own match can see an earlier iteration's failed match (Ruby: on this edge with
# `items = %w[q q]`, the first iteration reads "1" and the second nil).
def per_iteration(str, items)
  if str =~ /(\d+)/
    items.each do |i|
      assert_type("String?", $1)
      i =~ /(z)/
    end
  end
end

# Control: a body with no match reads the narrowing on every iteration.
def per_iteration_without_match(str, items)
  if str =~ /(\d+)/
    items.each { |_i| assert_type("String", $1) }
  end
end

# The block-return pass types the body under the same view (Ruby: ["1", nil] for `per_iteration_value("1q")`).
def per_iteration_value(str)
  chars = String(str).chars
  if str =~ /(\d+)/
    values = chars.map { |c| r = $1; c =~ /(z)/; r }
    assert_type("Array[String?]", values)
  end
end

# A `&expr` block argument may be a proc made in this frame, here by a method that keeps its block (Ruby:
# `block_pass("a1", ["q"])` returns nil).
def keep_block(&block) = block

def block_pass(str, items)
  matcher = keep_block { |i| i =~ /(zzz)/ }
  if str =~ /(\d+)/
    items.each(&matcher)
    assert_type("String?", $1)
  end
end

# Control: an anonymous `&` forwards the block this method was called with, which the caller made in its own
# frame (Ruby: `block_forward("a1", ["q"]) { |i| i =~ /(zzz)/ }` returns "1").
def block_forward(str, items, &)
  if str =~ /(\d+)/
    items.each(&)
    assert_type("String", $1)
  end
end

# Control: a Symbol block argument whose method cannot match (`&:freeze`) leaves the narrowing.
def block_pass_symbol(str, items)
  if str =~ /(\d+)/
    items.each(&:freeze)
    assert_type("String", $1)
  end
end

# A lambda made in the method rebinds the method's `$~` whenever it runs (Ruby: `lambda_call("a1")` returns nil).
def lambda_call(str)
  matcher = -> { "zz" =~ /(q)/ }
  if str =~ /(\d)/
    matcher.call
    assert_type("String?", $1)
  end
end

# `proc { }` likewise (Ruby: `proc_call("a1")` returns nil).
def proc_call(str)
  matcher = proc { "zz" =~ /(q)/ }
  if str =~ /(\d)/
    matcher.call
    assert_type("String?", $1)
  end
end

# Control: a lambda whose body cannot match leaves later calls match-free.
def lambda_without_match(str)
  shout = -> { "zz".upcase }
  if str =~ /(\d)/
    shout.call
    assert_type("String", $1)
  end
end

# Controls: inside a block, `[]`, `split` and `index` are lookups unless an argument is known to be a Regexp, so a
# hash copy, a String split and a lookup lambda leave the narrowing (Ruby: `lookup_copy("ab=c", [:a], {}, {})`
# returns "AB").
def lookup_copy(line, fields, row, out)
  if line =~ /^(\w+)=/
    fields.each { |f| out[f] = row[f] }
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

def split_parts(line, parts)
  if line =~ /^(\w+)=/
    parts.each { |part| part.split(":") }
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

def lookup_lambda(line, table)
  lookup = ->(k) { table[k] }
  if line =~ /^(\w+)=/
    lookup.call(:a)
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

# Control: the method's own `&block` parameter forwards the block its caller made, in the caller's frame (Ruby:
# `own_block("ab=c", ["q"]) { |i| i =~ /(zzz)/ }` returns "ab").
def own_block(line, env, &blk)
  if line =~ /^(\w+)=/
    env.each(&blk)
    key = $1
    assert_type("String", key)
    key.downcase
  end
end

# A `when` condition or an `in` pattern that may be a Regexp runs a match: a Regexp constant or a pinned variable
# (Ruby: nil for `block_when_constant("a1", ["zz"])` and `block_in_pinned("a1", ["zz"], /(q)/)`).
WORD_RE = /(\w)!/

def block_when_constant(str, items)
  if str =~ /(\d+)/
    items.each { |i| case i when WORD_RE then i end }
    assert_type("String?", $1)
  end
end

# Control: a `when` on a class runs `Module#===`, which does not match.
def block_when_class(str, items)
  if str =~ /(\d+)/
    items.each { |i| case i when String then i end }
    assert_type("String", $1)
  end
end

def block_in_pinned(str, items, pattern)
  if str =~ /(\d+)/
    items.each { |i| i in ^pattern }
    assert_type("String?", $1)
  end
end

# A matching block in the receiver chain runs while the statement does (Ruby: `chained("a1", ["q"])` reads nil).
def chained(str, items)
  if str =~ /(\d+)/
    items.select { |i| i =~ /(z)/ }.map(&:upcase)
    assert_type("String?", $1)
  end
end

# A parameter default runs in the method's frame, so a lambda there is the method's closure (Ruby:
# `default_closure("a1")` reads nil).
def default_closure(str, matcher = -> { "zz" =~ /(q)/ })
  if str =~ /(\d)/
    matcher.call
    assert_type("String?", $1)
  end
end

# `&:=~` runs `=~` on each element in this frame, and `$~ = …` in a block rebinds the slot directly (Ruby: nil for
# `symbol_match("a1", ["zz", /(q)/])` and `match_data_write("a1", [nil])`).
def symbol_match(str, pairs)
  if str =~ /(\d)/
    pairs.inject(&:=~)
    assert_type("String?", $1)
  end
end

def match_data_write(str, items)
  if str =~ /(\d)/
    items.each { |m| $~ = m }
    assert_type("String?", $1)
  end
end

# The per-element fold over a literal array types each position under the same view (Ruby: ["1", nil] for
# `per_element_value("a1")`).
def per_element_value(str)
  if str =~ /(\d+)/
    values = %w[q q].map { |c| r = $1; c =~ /(z)/; r }
    assert_type("[String?, String?]", values)
  end
end

# A captured local read before the body rebinds it carries an earlier iteration's `$1` (Ruby:
# `captured_previous("a1q")` returns ["x", "1", nil]).
def captured_previous(raw)
  str = String(raw)
  chars = str.chars
  last = "x"
  if str =~ /(\d+)/
    values = chars.map { |c| prev = last; last = $1; c =~ /(z)/; prev }
    assert_type('Array["x" | String | nil]', values)
  end
end

# A class body is a frame of its own, so a lambda made there rebinds the body's `$~` when it is called (Ruby: nil
# with `ARGV == ["a1"]`).
class ClassBodyFrame
  MATCHER = -> { "zz" =~ /(q)/ }
  LINE = ARGV.join
  if LINE =~ /(\d)/
    MATCHER.call
    assert_type("String?", $1)
  end
end
# rubocop:enable Style/PerlBackrefs
