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
# for each with `line = "ab=c"`). None of these frames holds a block that may match.
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

# A block whose body cannot match leaves the frame's implicit-self calls match-free (Ruby: "AB" for
# `callee_frame_plain_block("ab=c", ["q"])`).
def callee_frame_plain_block(line, items)
  items.each { |i| log_1364(i) }
  if line =~ /^(\w+)=(.*)$/
    log_1364("parsed")
    key = $1
    assert_type("String", key)
    key.upcase # CALLEE-FRAME
  end
end

# The call's own arguments run in this frame: a match there rebinds `$~` although the callee cannot, on any receiver
# and through a literal method name too, while an argument that only reads the globals leaves them (Ruby: nil for
# `operand_match("ab=c")`, for each `operand_*("a1", "q")` with `src = %q("zz" =~ /(q)/)` and `u = "zz"` for the
# `send`, and for `CalleeFrameRows.new(["zz", /(q)/]).inject_match("a1")`; "AB" for `operand_read("ab=c")`).
def operand_match(line)
  if line =~ /^(\w+)=(.*)$/
    log_1364(line.sub(/=/, ": "))
    assert_type("String?", $1)
  end
end

def operand_not_match(str, u)
  if str =~ /(\d+)/
    log_1364(u !~ /(z)/)
    assert_type("String?", $1)
  end
end

def operand_start_with(str, u)
  if str =~ /(\d+)/
    log_1364(u.start_with?(/(z)/))
    assert_type("String?", $1)
  end
end

def operand_any(str, u)
  if str =~ /(\d+)/
    log_1364([u].any?(/(z)/))
    assert_type("String?", $1)
  end
end

def operand_kernel_eval(str, src)
  if str =~ /(\d+)/
    log_1364(Kernel.eval(src))
    assert_type("String?", $1)
  end
end

def operand_send(str, u)
  if str =~ /(\d+)/
    log_1364(u.send(:=~, /(q)/))
    assert_type("String?", $1)
  end
end

# A `yield` in an argument runs the caller's block there, which may be a C-function proc (Ruby: nil for
# `operand_yield("a1", &:=~)`).
def operand_yield(str)
  if str =~ /(\d+)/
    log_1364(yield("zz", /(q)/))
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

# The implicit-self calls that reach this frame's slot forget it: `eval` runs its String here, and so does
# `instance_eval` in its String form; a `send` whose name is not a literal may be either (Ruby: nil for each with
# `str = "a1"` and `src = %q("zz" =~ /(q)/)`, and for `frame_send("a1", :eval, src)`).
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

# A core-class `self` inherits builtins that match on the caller's behalf, and an `Enumerable` runs a pattern or a
# Symbol-named method from C (Ruby: nil for `CalleeFrameLine.new("ab=c").inherited_match` and for
# `CalleeFrameRows.new(["q"]).pattern_predicate("a1")`).
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

  def inject_match(str)
    if str =~ /(\d+)/
      inject(:=~)
      assert_type("String?", $1)
    end
  end
end

# A block that runs while the statement does rebinds `$~` through `!~` or a Regexp-valued `start_with?` (Ruby: nil for
# `block_not_match("a1", ["q"])` and `block_start_with("a1", ["q"])`).
def block_not_match(str, items)
  if str =~ /(\d+)/
    items.each { |l| l !~ /(z)/ }
    assert_type("String?", $1)
  end
end

def block_start_with(str, items)
  if str =~ /(\d+)/
    items.each { |l| l.start_with?(/(z)/) }
    assert_type("String?", $1)
  end
end

# A frame that holds a block that may match forgets at every implicit-self call, as before #1364: the block runs in
# this frame, and a method it is handed to may keep it and run it from any later call, including through a lazy
# enumerator or `super` (Ruby: nil for `frame_block("a1")`, `CalleeFrameEmitter.new.kept_block("a1", "q")`,
# `CalleeFrameChild.new.hook("a1")` and `kept_lazy("a1", ["zz"])`).
def run_block_1364 = yield("q")

def frame_block(str)
  if str =~ /(\d+)/
    run_block_1364 { |x| x =~ /(z)/ }
    assert_type("String?", $1)
  end
end

class CalleeFrameEmitter
  def on(&handler) = @handler = handler
  def emit(*args) = @handler.call(*args)

  def kept_block(str, text)
    on { |l| l =~ /(z)/ }
    if str =~ /(\d+)/
      emit(text)
      assert_type("String?", $1)
    end
  end

  # The broad reading counts an `eval` in a kept block, which runs in this frame (Ruby: nil for
  # `CalleeFrameEmitter.new.kept_eval("a1")`).
  def kept_eval(str)
    on { |src| eval(src) }
    if str =~ /(\d+)/
      emit(%q("zz" =~ /(q)/))
      assert_type("String?", $1)
    end
  end

  # The block scan reads `!~` and a Regexp-valued `start_with?`, and the frame's broad reading counts a lookup whose
  # Regexp arrives as a block parameter (Ruby: nil for each with `str = "a1"`).
  def kept_not_match(str)
    on { |l| l !~ /(z)/ }
    if str =~ /(\d+)/
      emit("q")
      assert_type("String?", $1)
    end
  end

  def kept_start_with(str)
    on { |l| l.start_with?(/(z)/) }
    if str =~ /(\d+)/
      emit("q")
      assert_type("String?", $1)
    end
  end

  def kept_parameter_pattern(str)
    on { |l, pattern| l.index(pattern) }
    if str =~ /(\d+)/
      emit("zz", /(q)/)
      assert_type("String?", $1)
    end
  end
end

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

def force_1364(enum) = enum.first

def kept_lazy(str, items)
  lazy = items.lazy
  mapped = lazy.map { |i| i =~ /(q)/ }
  if str =~ /(\d+)/
    force_1364(mapped)
    assert_type("String?", $1)
  end
end

# A lambda literal is read broadly too, and so are a `yield` and a call on the method's own block inside a block the
# frame hands out, which run the caller's block, perhaps a C-function proc, in this frame (Ruby: nil for
# `CalleeFrameLambda.new.stored_lambda("a1")`, `yield_in_block_arg("a1", &:=~)` and
# `block_call_in_block_arg("a1", &:=~)`).
class CalleeFrameLambda
  def run_b(*args) = @b.call(*args)

  def stored_lambda(str)
    @b = ->(l, pattern) { l.index(pattern) }
    if str =~ /(\d+)/
      run_b("zz", /(q)/)
      assert_type("String?", $1)
    end
  end
end

def run_pair_1364 = yield("zz", /(q)/)

def yield_in_block_arg(str)
  if str =~ /(\d+)/
    run_pair_1364 { |a, b| yield a, b }
    assert_type("String?", $1)
  end
end

def block_call_in_block_arg(str, &blk)
  if str =~ /(\d+)/
    run_pair_1364 { |a, b| blk.call(a, b) }
    assert_type("String?", $1)
  end
end

# So does a frame that makes a `binding` in any spelling, which lets another method eval in this frame, or forwards
# its own block, which may be a C-function proc (Ruby: nil for `frame_binding("a1")`, `proc_binding("a1")`,
# `sent_binding("a1")` and `forwarded_block("a1", &:=~)`).
def eval_in_1364(frame) = frame.eval(%q("zz" =~ /(q)/))

def frame_binding(str)
  if str =~ /(\d+)/
    eval_in_1364(binding)
    assert_type("String?", $1)
  end
end

def proc_binding(str)
  if str =~ /(\d+)/
    eval_in_1364(proc {}.binding)
    assert_type("String?", $1)
  end
end

def sent_binding(str)
  if str =~ /(\d+)/
    eval_in_1364(send(:binding))
    assert_type("String?", $1)
  end
end

def forwarded_block(str, &blk)
  if str =~ /(\d+)/
    instance_exec("zz", /(q)/, &blk)
    assert_type("String?", $1)
  end
end

# `...` forwards the block as well (Ruby: nil for `forwarded_all("a1", "zz", /(q)/, &:=~)`).
def forwarded_all(str, ...)
  if str =~ /(\d+)/
    instance_exec(...)
    assert_type("String?", $1)
  end
end

# Control: the entry of a `then` / `tap` / `yield_self` block reads its body as every block's was read before #1364,
# without `!~` and the Regexp-valued `start_with?` family, so it stays as it was; the call still forgets afterwards
# (Ruby: "AB" for `once_block("ab=c")`).
def once_block(line)
  if line =~ /^(\w+)=/
    line.then do |l|
      k = $1
      assert_type("String", k)
      k.upcase if l !~ /x/
    end
    assert_type("String?", $1)
  end
end

# The same block with `=~` enters with the globals forgotten, as it did before #1364 (#1370's per-iteration rule):
# Kernel's `then` runs it once and Ruby reads "ab" (`once_match("ab=c")`), but the name alone cannot show that — a
# user `then` may keep the block, and a loop runs the call again (#1375).
def once_match(line)
  if line =~ /^(\w+)=/
    line.then do |l|
      k = $1
      assert_type("String?", k)
      l =~ /x/
    end
  end
end

# Ruby: `deferred_then("a1", CalleeFrameDeferred.new)` reads "1" on the first `resolve` and nil on the second, and
# `loop_then("a1", %w[q q])` reads "1" on the first pass and nil on the second.
class CalleeFrameDeferred
  def then(&blk) = (@blk = blk; self)
  def resolve(value) = @blk.call(value)
end

def deferred_then(str, deferred)
  if str =~ /(\d+)/
    deferred.then do |v|
      k = $1
      assert_type("String?", k)
      v =~ /(z)/
    end
    deferred.resolve("q")
    deferred.resolve("q")
  end
end

def loop_then(str, items)
  if str =~ /(\d+)/
    i = 0
    while i < items.size
      items[i].then do |v|
        k = $1
        assert_type("String?", k)
        v =~ /(z)/
      end
      i += 1
    end
  end
end

# Controls: an explicit-receiver call stays as before #1364 in a frame holding a block that may match, whatever the
# block is handed to (Ruby: "AB" for each with `line = "ab=c"`, `lines = ["x "]`, `h = {}`, `k = :user_id` and
# `cmd = "echo ok"`, and `ARGV == ["ab=c"]` for the class body).
def after_map_bang(line, lines)
  lines.map! { |l| l.sub(/\s+$/, "") }
  if line =~ /^(\w+)=/
    lines.push("x")
    name = $1
    name.upcase
  end
end

def after_sort_by_bang(line, lines)
  lines.sort_by! { |l| l[/\d+/].to_i }
  if line =~ /^(\w+)=/
    lines.push("x")
    name = $1
    name.upcase
  end
end

def after_reject_bang(line, lines)
  lines.reject! { |l| l =~ /^#/ }
  if line =~ /^(\w+)=/
    lines.push("x")
    name = $1
    name.upcase
  end
end

def after_to_h(line, lines)
  pairs = lines.to_h { |l| [l[/\A\w+/], l] }
  if line =~ /^(\w+)=/
    pairs.store("x", "y")
    name = $1
    name.upcase
  end
end

def after_popen(line, cmd)
  out = []
  IO.popen(cmd) { |io| io.each_line { |l| out << l if l =~ /ok/ } }
  if line =~ /^(\w+)=/
    out.push("x")
    name = $1
    name.upcase
  end
end

def after_fetch(line, h, k)
  label = h.fetch(k) { |kk| kk.to_s.sub(/_id$/, "") }
  if line =~ /^(\w+)=/
    label.freeze
    name = $1
    name.upcase
  end
end

class CalleeFrameLocked
  def initialize = (@mutex = Mutex.new; @line = "k=v")

  def read(line)
    @mutex.synchronize { @line =~ /(k)/ }
    if line =~ /^(\w+)=/
      @line.freeze
      name = $1
      name.upcase
    end
  end
end

class CalleeFrameEngine
  def self.initializer(_name, &blk) = blk

  initializer "x" do |app| app.to_s =~ /(y)/ end
  line = ARGV.join
  if line =~ /^(\w+)=/
    line.dup
    name = $1
    name.upcase
  end
end

# Controls: `yield` and a call on the method's own `&block` keep the narrowing, as before #1364. They rebind this frame
# only when the caller passes a C-function proc such as `&:=~`, a gap the specification states (Ruby: "AB" for each
# with `line = "ab=c"` and a block that does not match).
def yield_parsed(line)
  if line =~ /^(\w+)=(.*)$/
    yield :parsed
    key = $1
    key.upcase
  end
end

def block_call_parsed(line, &blk)
  if line =~ /^(\w+)=(.*)$/
    blk.call(:parsed)
    key = $1
    key.upcase
  end
end

def yield_split(line)
  if line =~ /^(\w+)=(.*)$/
    $2.split(",").each { |v| yield v }
    key = $1
    key.upcase
  end
end

def yield_in_each(line, items)
  if line =~ /^(\w+)=(.*)$/
    items.each { |i| k = $1; yield k.upcase, i }
  end
end

# Issue #1365 — a call rebinds the frame's `$~` by the method it calls, on any receiver, and in any position of the
# statement: Ruby runs a call's receiver chain and arguments, an array or hash literal's values and an interpolation
# in the same frame. Each read below is Ruby's nil with `str = "a1"` and the arguments its comment gives.

# Builtins outside the old name table that set their caller's `$~` (`u = "q"`).
def rebind_not_match(str, u)
  if str =~ /(\d+)/
    u !~ /(z)/
    assert_type("String?", $1)
  end
end

def rebind_start_with(str, u)
  if str =~ /(\d+)/
    u.start_with?(/q(z)?/)
    assert_type("String?", $1)
  end
end

def rebind_byteindex(str, u)
  if str =~ /(\d+)/
    u.byteindex(/(z)/)
    assert_type("String?", $1)
  end
end

def rebind_byterindex(str, u)
  if str =~ /(\d+)/
    u.byterindex(/(z)/)
    assert_type("String?", $1)
  end
end

# `u = +"q"`: the store matches `q`, whose optional group did not participate.
def rebind_index_assign(str, u)
  if str =~ /(\d+)/
    u[/q(z)?/] = "x"
    assert_type("String?", $1)
  end
end

# Unary `~` matches `$_`.
def rebind_tilde(str)
  if str =~ /(\d+)/
    $_ = "k"
    ~/(z)/
    assert_type("String?", $1)
  end
end

# `send` with a literal name that matches, or a computed one, and an eval of a String on any receiver (`u = "zz"`,
# `name = :=~`, `obj = Object.new`, `src = %q("zz" =~ /(q)/)`).
def rebind_send_literal(str, u)
  if str =~ /(\d+)/
    u.send(:=~, /(q)/)
    assert_type("String?", $1)
  end
end

def rebind_send_computed(str, u, name)
  if str =~ /(\d+)/
    u.public_send(name, /(q)/)
    assert_type("String?", $1)
  end
end

def rebind_binding_eval(str, src)
  if str =~ /(\d+)/
    binding.eval(src)
    assert_type("String?", $1)
  end
end

def rebind_kernel_eval(str, src)
  if str =~ /(\d+)/
    Kernel.eval(src)
    assert_type("String?", $1)
  end
end

def rebind_instance_eval(str, obj, src)
  if str =~ /(\d+)/
    obj.instance_eval(src)
    assert_type("String?", $1)
  end
end

# A lookup with a Regexp argument, in statement or assignment position, and `scan` / `sub` with a String pattern, `===`
# on a Regexp and `grep` / `any?` with one (`u = "abc"`, `items = ["zz"]`, `pattern = /(q)/`). A Regexp held in a
# local or an unannotated parameter counts too.
def rebind_split(str, u)
  if str =~ /(\d+)/
    parts = u.split(/(,)/)
    [parts, assert_type("String?", $1)]
  end
end

def rebind_element(str, u)
  if str =~ /(\d+)/
    hit = u[/(z)/]
    [hit, assert_type("String?", $1)]
  end
end

def rebind_index_local(str, u)
  pattern = Regexp.new("(q)")
  if str =~ /(\d+)/
    u.index(pattern)
    assert_type("String?", $1)
  end
end

def rebind_index_parameter(str, u, pattern)
  if str =~ /(\d+)/
    u.index(pattern)
    assert_type("String?", $1)
  end
end

def rebind_scan_string(str, u)
  if str =~ /(\d+)/
    u.scan("q")
    assert_type("String?", $1)
  end
end

def rebind_sub_string(str, u)
  if str =~ /(\d+)/
    u.sub("q", "")
    assert_type("String?", $1)
  end
end

def rebind_case_equality(str, u)
  if str =~ /(\d+)/
    /(q)/ === u
    assert_type("String?", $1)
  end
end

def rebind_grep_block(str, items)
  if str =~ /(\d+)/
    items.grep(/(q)/) { |x| x }
    assert_type("String?", $1)
  end
end

def rebind_any(str, items)
  if str =~ /(\d+)/
    items.any?(/(q)/)
    assert_type("String?", $1)
  end
end

# A call in an operand: an array element, an argument, a receiver chain, a `rescue` modifier and an index `||=` (`u =
# "z"`, and `u = +"q"` for the `||=`, whose read matches `q` without the optional group).
def operand_array_element(str, u)
  if str =~ /(\d+)/
    [u.index(/(q)/)]
    assert_type("String?", $1)
  end
end

def operand_argument(str, u)
  out = []
  if str =~ /(\d+)/
    out.push(u.sub(/q/, ""))
    assert_type("String?", $1)
  end
end

def operand_receiver_chain(str, u)
  if str =~ /(\d+)/
    size = u.sub(/q/, "").size
    [size, assert_type("String?", $1)]
  end
end

def operand_rescue_modifier(str, u)
  if str =~ /(\d+)/
    hit = u[/(q)/] rescue nil
    [hit, assert_type("String?", $1)]
  end
end

def operand_index_or_write(str, u)
  if str =~ /(\d+)/
    u[/q(z)?/] ||= "x"
    assert_type("String?", $1)
  end
end

# The receiver chain runs before the call's own block, which reads the rebound `$1` (Ruby: `[nil]` for
# `operand_before_block("a1", "z")`).
def operand_before_block(str, u)
  if str =~ /(\d+)/
    u.sub(/q/, "").each_char.map { |_c| assert_type("String?", $1) }
  end
end

# A block literal that may match, in an array, hash or interpolation value (`items = ["q"]`).
def operand_array_block(str, items)
  if str =~ /(\d+)/
    found = [items.find { |i| i =~ /(z)/ }]
    [found, assert_type("String?", $1)]
  end
end

def operand_hash_block(str, items)
  if str =~ /(\d+)/
    found = { a: items.find { |i| i =~ /(z)/ } }
    [found, assert_type("String?", $1)]
  end
end

def operand_interpolation_block(str, items)
  if str =~ /(\d+)/
    text = "#{items.map { |i| i =~ /(z)/ }}"
    [text, assert_type("String?", $1)]
  end
end

# After a call that rebinds `$~`, the read is unproven and calling a method on it reports (Ruby: NoMethodError on nil
# for `explicit_rebind_read("ab=c", "q")` and `operand_rebind_read("ab=c", "q")`).
def explicit_rebind_read(line, u)
  if line =~ /^(\w+)=/
    u !~ /(z)/
    key = $1
    key.upcase # GENUINE-NIL
  end
end

def operand_rebind_read(line, u)
  if line =~ /^(\w+)=/
    [u.index(/(z)/)]
    key = $1
    key.upcase # GENUINE-NIL
  end
end

# Controls: none of these rebinds `$~` in Ruby, because a lookup's argument is not a Regexp, `match?` never sets it,
# `String === s` runs `Module#===`, and `grep` without a block leaves the caller's `$~` alone. Each reads "AB" with
# `line = "ab=c"`, `row = {name: 1}`, `csv = "a,b"`, `list = [1, 3]`, `s = "a-b"`, `lines = ["zz"]` and
# `patterns = {}`.
def keep_hash_lookup(line, row)
  if line =~ /^(\w+)=/
    val = row[:name]
    key = $1
    assert_type("String", key)
    [val, key.upcase] # KEEPS-1365
  end
end

def keep_split(line, csv)
  if line =~ /^(\w+)=/
    csv.split(",")
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

def keep_array_index(line, list)
  if line =~ /^(\w+)=/
    pos = list.index(3)
    key = $1
    assert_type("String", key)
    [pos, key.upcase] # KEEPS-1365
  end
end

def keep_string_index(line, s)
  if line =~ /^(\w+)=/
    s.index("z")
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

def keep_string_element(line, s)
  if line =~ /^(\w+)=/
    hit = s["z"]
    key = $1
    assert_type("String", key)
    [hit, key.upcase] # KEEPS-1365
  end
end

def keep_match_predicate(line, s)
  if line =~ /^(\w+)=/
    s.match?(/x/)
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

def keep_partition(line, s)
  if line =~ /^(\w+)=/
    head, _sep, tail = s.partition("-")
    key = $1
    assert_type("String", key)
    [head, tail, key.upcase] # KEEPS-1365
  end
end

def keep_slice(line, s)
  if line =~ /^(\w+)=/
    s.slice("q")
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

def keep_class_case_equality(line, s)
  if line =~ /^(\w+)=/
    String === s
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

def keep_grep_without_block(line, lines)
  if line =~ /^(\w+)=/
    lines.grep(/(z)/)
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

def keep_start_with_string(line, s)
  if line =~ /^(\w+)=/
    s.start_with?("x")
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

# `[]=` reads its index, not the value it stores.
def keep_index_store(line, patterns)
  if line =~ /^(\w+)=/
    patterns[:word] = /(\w+)/
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

def keep_send_literal(line, s)
  if line =~ /^(\w+)=/
    s.send(:match?, /x/)
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

# An implicit-self call whose argument is such a lookup runs a Ruby method, and the lookup leaves `$~` alone.
def keep_implicit_self_lookup(line, row)
  if line =~ /^(\w+)=/
    log_1364(row[:name])
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end

# The same calls in an operand leave it alone too.
def keep_operand_lookup(line, row, csv)
  out = []
  if line =~ /^(\w+)=/
    out.push(row[:name], [csv.split(",")], "#{row[:name]}")
    key = $1
    assert_type("String", key)
    key.upcase # KEEPS-1365
  end
end
# rubocop:enable Style/PerlBackrefs
