require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1429 — a class guard on a global or constant receiver typed `IO` narrows the arm as it narrows a local's.
# `$stdout` holds an `IO` here, and a test runs the same code with a `StringIO`, which is not an `IO` subclass, so the
# guarded call must not report. Ruby 4.0.5 answers nil, "" and nil under `STDOUT`, the captured text under a `StringIO`.

$stdout = STDOUT

def guarded_is_a = ($stdout.is_a?(StringIO) ? $stdout.string : nil) # QUIET-1429
def guarded_respond_to = ($stdout.respond_to?(:string) ? $stdout.string : "") # QUIET-1429
def guarded_case = (case $stdout when StringIO then $stdout.string end) # QUIET-1429
def guarded_constant = (STDOUT.is_a?(StringIO) ? STDOUT.string : nil) # QUIET-1429

# `StringIO` is disjoint from `IO`, so the arm reads `bot`, as it does for a local, and nothing in it is checked.
# `respond_to?` names no class, so it admits the method with an untyped receiver.
def is_a_type = (assert_type("bot", $stdout) if $stdout.is_a?(StringIO))
def kind_of_type = (assert_type("bot", $stdout) if $stdout.kind_of?(StringIO))
def instance_of_type = (assert_type("bot", $stdout) if $stdout.instance_of?(StringIO))
def case_equality_type = (assert_type("bot", $stdout) if StringIO === $stdout)
def respond_to_type = (assert_type("Dynamic[top]", $stdout) if $stdout.respond_to?(:string))
def constant_type = (assert_type("bot", STDOUT) if STDOUT.is_a?(StringIO))
def rooted_constant_type = (assert_type("bot", ::STDOUT) if ::STDOUT.is_a?(StringIO))
def constant_case_type = (case STDOUT when StringIO then assert_type("bot", STDOUT) end)

# The arm is not checked, so a misspelling in it does not report either (Ruby: NoMethodError under a `StringIO`).
# Keeping such an arm checked is #1465.
def misspelled_in_arm = ($stdout.strnig if $stdout.is_a?(StringIO))

# The falsey edge keeps the entry type, and the `bot` arm adds nothing to the join.
def joined_type
  assert_type("IO", $stdout) unless $stdout.is_a?(StringIO)
  assert_type("IO", $stdout)
end

# The `case` value drops the arm, as it does for a local (Ruby: :io under `STDOUT`). Keeping it is #1465.
def case_value = assert_type(":io", (case $stdout when StringIO then :string_io else :io end))

# Control: an unguarded class-specific call on an `IO`-typed receiver still reports (Ruby: NoMethodError).
def unguarded = $stdout.string # FIRES-1429 call.undefined-method
def unguarded_constant = STDOUT.string # FIRES-1429 call.undefined-method

# A narrowing is keyed by the reference's spelling: `::STDOUT` guards `::STDOUT`, not `STDOUT`.
def other_spelling = (::STDOUT.is_a?(StringIO) ? STDOUT.string : nil) # FIRES-1429 call.undefined-method
