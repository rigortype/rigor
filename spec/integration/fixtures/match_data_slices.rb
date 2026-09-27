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

# A match with fewer groups after an earlier one: the slice follows the later match, so a size check on it is not
# folded (Ruby: `("abc", "x")` gives `$~[1..3] == ["x"]`) (#1385).
def when_arm_after_match(line, t)
  return unless line =~ /(a)(b)(c)/

  case t
  when /(x)/
    parts = $~[1..3]
    return :short if parts.size == 1
  end
  :long
end

def and_operand_after_match(line, t)
  if line =~ /(a)(b)(c)/ && t =~ /(x)/
    parts = $~[1..3]
    return :short if parts.size < 3
  end
  :long
end

# Control: a genuine three-group match still folds.
def three_groups(line)
  return unless line =~ /(a)(b)(c)/

  assert_type("[String, String, String]", $~[1..3])
end

# A named group makes a plain group non-capturing, so `/(?<key>\w+)=(\w+)/` has one group and the slice is not
# folded to two slots (Ruby: `"k=v"` gives `$~[1..2] == ["k"]`) (#1471). Named groups alone fold.
def named_and_plain(line)
  return unless line =~ /(?<key>\w+)=(\w+)/

  parts = $~[1..2]
  return :one if parts.size == 1

  :two
end

def named_only(line)
  return unless line =~ /(?<a>x)(?<b>y)/

  assert_type("[String, String]", $~[1..2])
end

# A project class named `Regexp` is not the core class, so its `last_match` is not the frame's match; the core class
# spelled `::Regexp` still is.
module ShadowedRegexp
  class Regexp
    def self.last_match = "k".match(/(k)/)
  end

  def self.slice(line)
    return unless line =~ /(a)(b)(c)/

    assert_type("Array[String?]", Regexp.last_match[1..3])
    assert_type("[String, String, String]", ::Regexp.last_match[1..3])
  end
end
# rubocop:enable Style/SpecialGlobalVars
