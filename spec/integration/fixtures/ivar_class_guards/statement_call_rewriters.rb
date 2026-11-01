require "rigor/testing"
include Rigor::Testing

# Issue #2039 — a callee the #1596 proof cannot clear whose body rewrites the guarded variable with a computed value
# (`@tag = @tag.strip`, `@tag ||= "x"`, a parameter, a multiple assignment of a string), writes another variable,
# or writes `nil` only inside a lambda it never calls, shows no write that can be `nil` by its syntax
# (`DirectIvarWrites`), so the statement reset marks and the read stays quiet. Under Ruby 4.0.5 every `q*` returns a
# String; `clear_tag` is never called.
class H
  attr_reader :items

  def initialize
    @tag = "t"
    @items = []
    @count = 0
  end

  def strip_tag; @tag = @tag.strip; true; end
  def strip_tag_y; @tag = @tag.strip; yield if block_given?; true; end
  def norm_tag; @tag = @tag.to_s.downcase; items.any?; end
  def memo_tag; @tag ||= "x"; items.any?; end
  def dup_tag; @tag = @tag.dup; items.each { |i| i }; true; end
  def from_param(v); @tag = v; items.any?; end
  def deep1 = deep2
  def deep2; @tag = @tag.upcase; items.any?; end
  def other_ivar; @items = items.compact; items.any?; end
  def rescue_into; Integer("x"); rescue => @err; items.any?; end
  def multi; @a, @tag = 1, "s"; items.any?; end
  def lam; f = -> { @tag = nil }; f.arity; items.any?; end
  def str_tag; @tag = format("%s", "x"); items.any?; end
  def cnt; @count += 1; items.any?; end

  def q1; return unless @tag; strip_tag;          t = @tag; t.upcase; end # QUIET-1446
  def q2; return unless @tag; strip_tag_y;        t = @tag; t.upcase; end # QUIET-1446
  def q3; return unless @tag; norm_tag;           t = @tag; t.upcase; end # QUIET-1446
  def q4; return unless @tag; memo_tag;           t = @tag; t.upcase; end # QUIET-1446
  def q5; return unless @tag; dup_tag;            t = @tag; t.upcase; end # QUIET-1446
  def q6; return unless @tag; from_param("z");    t = @tag; t.upcase; end # QUIET-1446
  def q7; return unless @tag; deep1;              t = @tag; t.upcase; end # QUIET-1446
  def q8; return unless @tag; other_ivar;         t = @tag; t.upcase; end # QUIET-1446
  def q9; return unless @tag; rescue_into;        t = @tag; t.upcase; end # QUIET-1446
  def q10; return unless @tag; multi;             t = @tag; t.upcase; end # QUIET-1446
  def q11; return unless @tag; lam;               t = @tag; t.upcase; end # QUIET-1446
  def q12; return unless @tag; str_tag;           t = @tag; t.upcase; end # QUIET-1446
  def q13; return unless @tag; cnt;               t = @tag; t.upcase; end # QUIET-1446
  def q14; return unless @tag; strip_tag_y { 1 }; t = @tag; t.upcase; end # QUIET-1446
  def q15; return unless @tag; self.strip_tag_y;  t = @tag; t.upcase; end # QUIET-1446

  def clear_tag = (@tag = nil)
end

# Issue #2482 — values that look nil-capable but that Ruby never binds to `nil`: an `||` whose left side is a truthy
# literal, an Array literal or an Array-valued call splatted across the targets, a plain call past a safe-navigation
# call (which raises on a `nil` receiver), and a `case ... in` with no `else` (which raises NoMatchingPatternError).
# Under Ruby 4.0.5 every `q*` returns a String.
class ShapeRewriters
  attr_reader :items

  def initialize
    @tag = "t"
    @items = []
    @peer = "p"
    @k = 1
  end

  def or_lit; @tag = "a" || nil; items.any?; end
  def multi_arr; @a, @tag = [1, "s"]; items.any?; end
  def multi_call; @a, @tag = pair; items.any?; end
  def chain_plain; @tag = @peer&.upcase.strip; items.any?; end
  def case_in; @tag = case @k
                      in Integer then "a"
                      end; items.any?; end

  def pair = [1, "s"]

  def q1; return unless @tag; or_lit;      t = @tag; t.upcase; end # QUIET-1446
  def q2; return unless @tag; multi_arr;   t = @tag; t.upcase; end # QUIET-1446
  def q3; return unless @tag; multi_call;  t = @tag; t.upcase; end # QUIET-1446
  def q4; return unless @tag; chain_plain; t = @tag; t.upcase; end # QUIET-1446
  def q5; return unless @tag; case_in;     t = @tag; t.upcase; end # QUIET-1446
end
