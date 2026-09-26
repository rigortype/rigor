require "rigor/testing"
include Rigor::Testing

# Issue #1429 — truthiness, `nil?`, `!` and `&.` narrow a global or constant read as they narrow a local. The file
# writes `nil` to `$sep` on one path, so without the guard a copy of it reports a possible nil receiver (Ruby: 1 when
# an argument is given, and no call otherwise).

$sep = nil if ARGV.empty?
$sep = "," unless ARGV.empty?
SEP = ARGV.empty? ? nil : ","

def unless_return
  return unless $sep

  copy = $sep
  copy.length # QUIET-1429
end

def if_guard
  if $sep
    copy = $sep
    copy.length # QUIET-1429
  end
end

def nil_predicate
  return if $sep.nil?

  copy = $sep
  copy.length # QUIET-1429
end

def negated_nil_predicate
  return unless !$sep.nil?

  copy = $sep
  copy.length # QUIET-1429
end

def safe_navigation
  return unless $sep&.start_with?(",")

  copy = $sep
  copy.length # QUIET-1429
end

def constant_guard
  return unless SEP

  copy = SEP
  copy.length # QUIET-1429
end

def constant_nil_predicate
  return if SEP.nil?

  copy = SEP
  copy.length # QUIET-1429
end

def narrowed_types
  assert_type('","', $sep) if $sep
  assert_type("nil", $sep) unless $sep
  assert_type('","', $sep) unless $sep.nil?
  assert_type('","', SEP) if SEP
end

# Control: the unguarded copies still report.
def unguarded
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def unguarded_constant
  copy = SEP
  copy.length # FIRES-1429 call.possible-nil-receiver
end
