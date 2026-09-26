require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1429 (ADR-117 Decision point 3) — a class guard is code evidence, so it protects the call it guards on a
# global or constant receiver typed `IO`. `$stdout` holds an `IO` here, and a test runs the same code with a `StringIO`,
# which is not an `IO` subclass. Ruby 4.0.5 answers nil, "" and nil under `STDOUT`, the captured text under a `StringIO`.

$stdout = STDOUT

def guarded_is_a = ($stdout.is_a?(StringIO) ? $stdout.string : nil) # QUIET-1429
def guarded_respond_to = ($stdout.respond_to?(:string) ? $stdout.string : "") # QUIET-1429
def guarded_case = (case $stdout when StringIO then $stdout.string end) # QUIET-1429
def guarded_constant = (STDOUT.is_a?(StringIO) ? STDOUT.string : nil) # QUIET-1429

# The ordinary reading proves the arm dead, so the guard makes it gradual: the receiver reads `Dynamic[StringIO]`, a
# call on it is typed through `StringIO`, and `respond_to?` admits the method with an untyped receiver.
def is_a_type = (assert_type("Dynamic[StringIO]", $stdout) if $stdout.is_a?(StringIO))
def kind_of_type = (assert_type("Dynamic[StringIO]", $stdout) if $stdout.kind_of?(StringIO))
def instance_of_type = (assert_type("Dynamic[StringIO]", $stdout) if $stdout.instance_of?(StringIO))
def case_equality_type = (assert_type("Dynamic[StringIO]", $stdout) if StringIO === $stdout)
def respond_to_type = (assert_type("Dynamic[top]", $stdout) if $stdout.respond_to?(:string))
def constant_type = (assert_type("Dynamic[StringIO]", STDOUT) if STDOUT.is_a?(StringIO))
def rooted_constant_type = (assert_type("Dynamic[StringIO]", ::STDOUT) if ::STDOUT.is_a?(StringIO))
def constant_case_type = (case STDOUT when StringIO then assert_type("Dynamic[StringIO]", STDOUT) end)
def typed_call = (assert_type("String", $stdout.string) if $stdout.is_a?(StringIO))

# Method availability inside the arm is still checked against the guarded class (Ruby: NoMethodError under a
# `StringIO`).
def misspelled_in_arm = ($stdout.strnig if $stdout.is_a?(StringIO)) # FIRES-1429 call.undefined-method
def misspelled_on_constant = (STDOUT.strnig if STDOUT.is_a?(StringIO)) # FIRES-1429 call.undefined-method

# The falsey edge keeps the entry type, and the guarded arm joins back as a gradual member.
def joined_type
  assert_type("IO", $stdout) unless $stdout.is_a?(StringIO)
  assert_type("Dynamic[StringIO] | IO", $stdout)
end

# The `case` value keeps the arm the guard names, as a gradual value (Ruby: :io under `STDOUT`).
def case_value = assert_type(":io | Dynamic[:string_io]", (case $stdout when StringIO then :string_io else :io end))

# Control: an unguarded class-specific call on an `IO`-typed receiver still reports (Ruby: NoMethodError).
def unguarded = $stdout.string # FIRES-1429 call.undefined-method
def unguarded_constant = STDOUT.string # FIRES-1429 call.undefined-method

# A narrowing is keyed by the reference's spelling: `::STDOUT` guards `::STDOUT`, not `STDOUT`.
def other_spelling = (::STDOUT.is_a?(StringIO) ? STDOUT.string : nil) # FIRES-1429 call.undefined-method
