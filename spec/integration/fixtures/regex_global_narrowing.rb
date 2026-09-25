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
# The locals date from when an implicit-self call such as `assert_type`
# forgot the match globals; since #1364 it no longer does.
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

# Controls: none of these runs a `===` that can match, so the narrowing stays and `key.upcase` is quiet (Ruby: "AB"
# for each with `line = "ab=c"`). A `case` without a subject tests each condition for truth; `*KEYS`, `KEYS` and
# `LIMITS` are collections, whose `===` is equality; an `in` guard is ordinary code; and a constant that does not
# resolve is read as a class.
KEYS = %w[a b].freeze
LIMITS = { a: 1 }.freeze

def subjectless_case(line, items)
  if line =~ /^(\w+)=/
    items.each { |i| case; when i.empty? then i; end }
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

def splat_constant_when(line, items)
  if line =~ /^(\w+)=/
    items.each { |i| case i when *KEYS then i end }
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

def collection_constant_when(line, items)
  if line =~ /^(\w+)=/
    items.each { |i| case i when KEYS, LIMITS then i end }
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

def pattern_guard(line, items)
  if line =~ /^(\w+)=/
    items.each do |i|
      case i
      in { k: v } if LIMITS.key?(v) && v.to_s.match?(/\A[a-z]\z/) then v
      else nil
      end
    end
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

def unresolved_constant_when(line, items)
  if line =~ /^(\w+)=/
    items.each { |i| case i when Some::Unknown::Klass then i end }
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

# Control: `grep` without a block leaves the caller's `$~` alone (Ruby: "AB" for
# `grep_without_block("ab=c", [["zz"]])`).
def grep_without_block(line, groups)
  if line =~ /^(\w+)=/
    groups.each { |g| g.grep(/(z)/) }
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

# `grep` with a block rebinds it (Ruby: nil for `grep_with_block("a1", [["zz"]])`).
def grep_with_block(str, groups)
  if str =~ /(\d+)/
    groups.each { |g| g.grep(/(q)/) { |x| x } }
    assert_type("String?", $1)
  end
end

# A lookup argument bound to a Regexp where the block is written rebinds `$~` (Ruby: nil for
# `local_regexp_lookup("a1", ["zz"])` and `constructed_regexp_index("a1", ["zz"])`).
def local_regexp_lookup(str, items)
  pattern = /(q)/
  if str =~ /(\d+)/
    items.each { |i| i[pattern] }
    assert_type("String?", $1)
  end
end

def constructed_regexp_index(str, items)
  pattern = Regexp.new("(q)")
  if str =~ /(\d+)/
    items.each { |i| i.index(pattern) }
    assert_type("String?", $1)
  end
end

# Issue #1364 — a method defined in Ruby runs in a frame of its own, so a match in its body rebinds its own `$~`,
# never its caller's: an implicit-self or `self.` call between the match and the read keeps the narrowing (Ruby: "AB"
# for each with `line = "ab=c"`).
def log_1364(msg) = msg

def callee_frame_log(line)
  if line =~ /^(\w+)=(.*)$/
    log_1364("parsed")
    key = $1
    assert_type("String", key)
    key.upcase # CALLEE-FRAME
  end
end

def callee_frame_warn(line)
  if line =~ /^(\w+)=(.*)$/
    warn "debug"
    key = $1
    assert_type("String", key)
    key.upcase # CALLEE-FRAME
  end
end

class CalleeFrameParser
  def log(msg) = msg

  def callee_frame_self_log(line)
    if line =~ /^(\w+)=(.*)$/
      self.log("x")
      key = $1
      assert_type("String", key)
      key.upcase # CALLEE-FRAME
    end
  end
end

# A `send` whose name is a literal that cannot match dispatches to a Ruby method, which is a frame of its own.
def callee_frame_send_literal(line)
  if line =~ /^(\w+)=(.*)$/
    send(:log_1364, line)
    key = $1
    assert_type("String", key)
    key.upcase # CALLEE-FRAME
  end
end

# The call's own arguments run in this frame: a match there rebinds `$~` although the callee cannot, while an
# argument that only reads the globals leaves them (Ruby: nil for `operand_match("ab=c")`, "AB" for
# `operand_read("ab=c")`).
def operand_match(line)
  if line =~ /^(\w+)=(.*)$/
    log_1364(line.sub(/=/, ": "))
    assert_type("String?", $1)
  end
end

def operand_read(line)
  if line =~ /^(\w+)=(.*)$/
    log_1364("#{$2.strip}: parsed")
    key = $1
    assert_type("String", key)
    key.upcase
  end
end

# Control: after a call that does reach this frame's slot the read is unproven, and calling a method on it reports
# (Ruby: `frame_eval_read("ab=c", %q("zz" =~ /(q)/))` raises NoMethodError on nil).
def frame_eval_read(line, src)
  if line =~ /^(\w+)=(.*)$/
    eval(src)
    key = $1
    key.upcase # GENUINE-NIL
  end
end

# The calls that still reach this frame's slot forget it. A block this frame made runs in it (Ruby: nil for
# `frame_block("a1")`).
def run_block_1364 = yield("q")

def frame_block(str)
  if str =~ /(\d+)/
    run_block_1364 { |x| x =~ /(z)/ }
    assert_type("String?", $1)
  end
end

# `eval` runs its String in this frame, and so does `instance_eval` in its String form; a `send` whose name is not a
# literal may be either (Ruby: nil for each with `str = "a1"` and `src = %q("zz" =~ /(q)/)`, and for
# `frame_send("a1", :eval, src)`).
def frame_eval(str, src)
  if str =~ /(\d+)/
    eval(src)
    assert_type("String?", $1)
  end
end

def frame_instance_eval(str, src)
  if str =~ /(\d+)/
    instance_eval(src)
    assert_type("String?", $1)
  end
end

def frame_send(str, name, src)
  if str =~ /(\d+)/
    send(name, src)
    assert_type("String?", $1)
  end
end

# `yield` and a call on the method's own `&block` run the block the caller passed, which may be a C-function proc
# whose method sets this frame's slot (Ruby: nil for `frame_yield("a1", &:=~)` and `frame_block_call("a1", &:=~)`).
def frame_yield(str)
  if str =~ /(\d+)/
    yield "zz", /(q)/
    assert_type("String?", $1)
  end
end

def frame_block_call(str, &blk)
  if str =~ /(\d+)/
    blk.call("zz", /(q)/)
    assert_type("String?", $1)
  end
end

# Inside a block they count the same way, since the block runs in this frame (Ruby: nil for
# `frame_yield_in_block("a1", ["zz"], &:=~)` and `frame_eval_in_block("a1", [%q("zz" =~ /(q)/)])`).
def frame_yield_in_block(str, items)
  if str =~ /(\d+)/
    items.each { |i| yield i, /(q)/ }
    assert_type("String?", $1)
  end
end

def frame_eval_in_block(str, sources)
  if str =~ /(\d+)/
    sources.each { |src| eval(src) }
    assert_type("String?", $1)
  end
end

# A block handed to a method that may keep it runs in this frame whenever a later call runs it, through self or
# through the receiver that kept it, so every call in the frame forgets (Ruby: nil for
# `CalleeFrameEmitter.new.kept_block("a1", "q")` and `kept_block_receiver("a1", CalleeFrameEmitter.new, "q")`).
class CalleeFrameEmitter
  def on(key, &handler) = (@handlers ||= {})[key] = handler
  def emit(key, *args) = @handlers.fetch(key).call(*args)

  def kept_block(str, text)
    on(:line) { |l| l =~ /(z)/ }
    if str =~ /(\d+)/
      emit(:line, text)
      assert_type("String?", $1)
    end
  end
end

def kept_block_receiver(str, bus, text)
  bus.on(:line) { |l| l =~ /(z)/ }
  if str =~ /(\d+)/
    bus.emit(:line, text)
    assert_type("String?", $1)
  end
end

# `super` hands its block to the superclass method, which may keep it (Ruby: nil for
# `CalleeFrameChild.new.hook("a1")`).
class CalleeFrameHooks
  def hook(_str, &handler) = @handler = handler
  def fire(*args) = @handler.call(*args)
end

class CalleeFrameChild < CalleeFrameHooks
  def hook(str)
    super { |l| l =~ /(z)/ }
    if str =~ /(\d+)/
      fire("q")
      assert_type("String?", $1)
    end
  end
end

# A lazy enumerator keeps its block until it is forced, and a `binding` lets another method eval in this frame
# (Ruby: nil for `kept_lazy("a1", ["q"])` and `frame_binding("a1")`).
def kept_lazy(str, items)
  lazy = items.lazy.map { |i| i =~ /(z)/ }
  if str =~ /(\d+)/
    lazy.first
    assert_type("String?", $1)
  end
end

def eval_in_1364(frame) = frame.eval(%q("zz" =~ /(q)/))

def frame_binding(str)
  if str =~ /(\d+)/
    eval_in_1364(binding)
    assert_type("String?", $1)
  end
end

# Controls: a core iterator, or a method named by the `each_` convention, runs its block before it returns, so a
# match there before the guard leaves later calls match-free (Ruby: "1" for `block_run_now("a1", ["q"])` and
# `each_prefix_run_now("a1", ["q"])`).
def block_run_now(str, items)
  items.each { |i| i =~ /(z)/ }
  if str =~ /(\d+)/
    str.upcase
    assert_type("String", $1)
  end
end

def each_row_1364(rows) = rows.each { |r| yield r }

def each_prefix_run_now(str, rows)
  each_row_1364(rows) { |r| r =~ /(z)/ }
  if str =~ /(\d+)/
    str.upcase
    assert_type("String", $1)
  end
end

# A core-class `self` inherits builtins that match on the caller's behalf (Ruby: nil for
# `CalleeFrameLine.new("ab=c").inherited_match` and `CalleeFrameRows.new(["q"]).pattern_predicate("a1")`).
class CalleeFrameLine < String
  def inherited_match
    if self =~ /(\w+)=/
      start_with?(/(z)/)
      assert_type("String?", $1)
    end
  end
end

class CalleeFrameRows
  include Enumerable

  def initialize(rows) = @rows = rows
  def each(&) = @rows.each(&)

  def pattern_predicate(str)
    if str =~ /(\d+)/
      any?(/(z)/)
      assert_type("String?", $1)
    end
  end
end
# rubocop:enable Style/PerlBackrefs
