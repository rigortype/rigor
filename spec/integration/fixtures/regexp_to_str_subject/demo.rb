# frozen_string_literal: true

# Issue #2002 — `Regexp#===` (and `case x when /re/`) converts a subject whose class defines `to_str`, so the match
# edge keeps such a member whole; a class its signature declares without `to_str` cannot match and leaves the edge.
# The classes here are declared in `sig/subjects.rbs`. Ruby (4.0.5), each true unless noted:
#   /\A\d+\z/ === SigToStr.new        # to_str "12"
#   /\A\d+\z/ === SigChild.new        # inherits to_str
#   /\A\d+\z/ === SigMixed.new        # to_str from ToStrMixin
#   /\A\d+\z/ === SigPlain.new        # => false, no to_str
class SigToStr
  def to_str = "12"
end

class SigPlain
  def name = "plain"
end

class SigChild < SigToStr
end

module ToStrMixin
  def to_str = "12"
end

class SigMixed
  include ToStrMixin
end

def case_equality_sig_to_str
  c = SigToStr.new
  assert_type("SigToStr", c) if /\A\d+\z/ === c
end

def case_when_sig_child
  c = SigChild.new
  case c
  when /\A\d+\z/
    assert_type("SigChild", c)
  end
end

def case_equality_sig_mixed
  c = SigMixed.new
  assert_type("SigMixed", c) if /\A\d+\z/ === c
end

def case_equality_sig_plain
  c = SigPlain.new
  assert_type("bot", c) if /\A\d+\z/ === c
end

def case_when_sig_plain_or_to_str(flag)
  c = flag ? SigPlain.new : SigToStr.new
  case c
  when /\A\d+\z/
    assert_type("SigToStr", c)
  else
    assert_type("SigPlain | SigToStr", c)
  end
end

# An `Object`, `BasicObject` or module subject narrows to its String and Symbol parts on the match edge, so a String
# method called there reports nothing (Ruby: `Probe.new.object_length("12")` is 2, `basic_upcase("1a")` is "1A",
# `object_or_nil_to_i("12")` is 12). Parameter types come from `sig/subjects.rbs`.
class Probe
  def object_length(s)
    assert_type("String | Symbol", s) if /\d/ === s
    s.length if /\d/ === s
  end

  def basic_upcase(s)
    case s
    when /\d/ then s.upcase
    end
  end

  def object_or_nil_to_i(s)
    s.to_i if /\d/ === s
  end

  def kernel_subject(s)
    assert_type("String | Symbol", s) if /\d/ === s
  end
end
