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
# rubocop:enable Style/PerlBackrefs
