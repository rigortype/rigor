# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1381 — on a proven match a constant slice of `$~` reads a Tuple, one slot per capture group: `String` for a
# group every successful match sets, `String?` for an optional one, and `String` for index 0, the whole match.

# The #1381 repro (redmine's redcloth3): destructuring the slice binds each group's slot, and the call is silent.
def repro(line)
  return unless line =~ /(a)(b)(c)/

  tl, atts, content = $~[1..3]
  [tl.length, atts.length, content.length]
end

def slices(line)
  return unless line =~ /(a)(b)?(c)/

  assert_type("[String, String?, String]", $~[1..3])
  assert_type("[String, String?]", $~[1...3])
  assert_type("[String, String]", $~[0..1])
  assert_type("[String, String?]", $~[1, 2])
  assert_type("[String, String]", $~.values_at(1, 3))
  assert_type("[String, String?]", Regexp.last_match[1..2])
  assert_type("[String?, String]", Regexp.last_match[2, 2])
end

# Control: the optional group's slot read through the Tuple still carries its nil.
def optional_group(line)
  return unless line =~ /(a)(b)?(c)/

  atts = $~[1..3][1]
  atts.length # GENUINE-NIL
end

# Declines keep RBS's answer: an endless or negative range, an index past the highest group the match proves, a
# match that binds no numbered group, a MatchData held in a local, and a non-constant index.
def declines(line)
  index = line.size
  if line =~ /(a)(b)(c)/
    assert_type("Array[String?]", $~[1..])
    assert_type("Array[String?]", $~[-2..3])
    assert_type("Array[String?]", $~[2..4])
    assert_type("Array[String?]", $~.values_at(1, 4))
    match = $~
    assert_type("Array[String?]", match[1..2])
    assert_type("Array[String?]", $~[1..index])
  end
  assert_type("Array[String?]", $~[0..0]) if line =~ /a/
end

# Without a proven match nothing changes: no match before the read, or the falsey edge of one.
def unproven(line)
  assert_type("Array[String?]", Regexp.last_match[1..2])
  assert_type("Array[String?]", Regexp.last_match[1..2]) unless line =~ /(a)(b)/
end
# rubocop:enable Style/SpecialGlobalVars
