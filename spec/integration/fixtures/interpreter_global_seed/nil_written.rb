# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1362 — where this file writes `nil` to a separator itself, a copy reports as it did before #1362. The
# separators are not joined with their declared type yet (#1437), so each reads the union of this file's writes; the
# join shapes below keep reporting when #1437 joins them, since the file's own `nil` is diagnostic fuel.

$\ = nil
$/ = ","
$, = "-"
$; = nil

def clear_separator = ($/ = nil)

# Ruby: `NoMethodError` once the file's `$\ = nil` ran.
def terminator_size
  terminator = $\
  terminator.size # FIRES-1362 call.undefined-method
end

# Ruby: `NoMethodError` once `clear_separator` ran.
def separator_length
  sep = $/
  sep.length # FIRES-1362 call.possible-nil-receiver
end

# A local two branches copy from different globals (Ruby: `NoMethodError` once `clear_separator` ran and the first
# branch was taken).
def joined_copies(flag)
  if flag then sep = $/ else sep = $, end
  sep.length # FIRES-1362 call.possible-nil-receiver
end

def rebound_to_other_copy(flag)
  sep = $,
  sep = $/ if flag
  sep.size # FIRES-1362 call.possible-nil-receiver
end

# The same across a `retry` (Ruby: `NoMethodError` on the retried pass once `clear_separator` ran).
def retried_copy(flag)
  sep = $,
  begin
    sep.length # FIRES-1362 call.possible-nil-receiver
    raise if flag
  rescue StandardError
    sep = $/
    retry
  end
end

# A retried pass that re-enters with a copy of `$;`, which the file sets to `nil` (Ruby: `NoMethodError` on the
# retried pass).
def retried_rebound_copy(flag)
  sep = $,
  begin
    sep.match?("a") # FIRES-1362 call.possible-nil-receiver
    raise if flag
  rescue StandardError
    sep = $;
    retry
  end
end
# rubocop:enable Style/SpecialGlobalVars
