# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1362 (ADR-58 parity, ADR-117 Decision point 2) — the declared `nil` of a global's seed is real type
# information but not diagnostic fuel, directly or through a local copied from the global: this file never writes
# `nil` to any of them. Each method runs with whatever the command line or another file set last; the cited answer
# is Ruby 4.0.5's once this file's writes ran.

$/ = ","
$, = "-"
$\ = "\n"
$-0 = "\n"
$-i = ".bak"

# The copy reads `"," | String | nil`, the seed, and its method stays quiet (Ruby: 1).
def plain_copy
  sep = $/
  assert_type('"," | String | nil', sep)
  sep.length # QUIET-1362
end

# A guard on the global narrows nothing yet (#1429), so the copy after it reads the seed as well (Ruby: 1).
def guarded_unless
  return unless $/

  sep = $/
  sep.length # QUIET-1362
end

def guarded_nil_check
  return if $/.nil?

  sep = $/
  sep.length # QUIET-1362
end

def output_separator_copy
  sep = $,
  sep.size # QUIET-1362
end

def output_separator_in_condition
  if $,
    sep = $,
    sep.size # QUIET-1362
  end
end

def record_terminator_copy
  terminator = $\
  terminator.size # QUIET-1362
end

def dash_zero_copy
  separator = $-0
  separator.size # QUIET-1362
end

def in_place_extension_copy
  extension = $-i
  extension.size # QUIET-1362
end

# A copy of a copy, and a parenthesised read, carry the seed's mark as the bare copy does (Ruby: 1 for each).
def copy_of_copy
  sep = $,
  copy = sep
  copy.size # QUIET-1362
end

def parenthesised_copy
  sep = ($,)
  sep.size # QUIET-1362
end

# A local two branches copy from different globals keeps the mark with both globals, and neither file write is
# `nil` (Ruby: 1).
def joined_copies(flag)
  if flag then sep = $/ else sep = $, end
  sep.length # QUIET-1362
end

def retried_copy(flag)
  sep = $,
  begin
    sep.length # QUIET-1362
    raise if flag
  rescue StandardError
    sep = $/
    retry
  end
end

# Known false positive of ADR-58's one-hop boundary: a method result carries no mark, so the declared `nil` reaches
# the report (Ruby: 1). Flip this to QUIET-1362 if the boundary is widened to method results (ADR-58 WD1b).
def duplicated_copy
  sep = $,.dup
  sep.size # FIRES-1362 call.possible-nil-receiver
end

# Controls: a `nil` the method binds itself is flow-live and still reports.
def rebound_copy(flag)
  sep = $/
  sep = nil if flag
  sep.length # FIRES-1362 call.possible-nil-receiver
end

def written_in_method
  $; = nil
  separator = $;
  separator.size # FIRES-1362 call.undefined-method
end

# A compound write is flow-live as well, and the pre-pass does not add it to the file's writes: the copy after it
# reads the binding the method made.
def compound_written
  $\ ||= nil
  terminator = $\
  terminator.size # FIRES-1362 call.possible-nil-receiver
end
# rubocop:enable Style/SpecialGlobalVars
