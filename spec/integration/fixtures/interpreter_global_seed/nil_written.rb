# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1362 — controls for the withheld declared `nil`: where this file writes `nil` to the global itself, a copy's
# `nil` is not the declaration's alone, and the report its writes earned before the join still fires.

$\ = nil
$/ = ","
$, = "-"
$; = nil

def clear_separator = ($/ = nil)

# Ruby: `NoMethodError` once the file's `$\ = nil` ran.
def terminator_size
  terminator = $\
  terminator.size # FIRES-1362 call.possible-nil-receiver
end

# Ruby: `NoMethodError` once `clear_separator` ran.
def separator_length
  sep = $/
  sep.length # FIRES-1362 call.possible-nil-receiver
end

# A local two branches copy from different globals keeps the file's writes to both as fuel, so the `nil` the file
# writes to `$/` still reports (Ruby: `NoMethodError` once `clear_separator` ran and the first branch was taken).
def joined_copies(flag)
  if flag then sep = $/ else sep = $, end
  sep.length # FIRES-1362 call.possible-nil-receiver
end

def rebound_to_other_copy(flag)
  sep = $,
  sep = $/ if flag
  sep.size # FIRES-1362 call.possible-nil-receiver
end

# The same across a `retry`: the retried pass re-enters with a copy of `$/`, which the entry's copy of `$,` accepts,
# so nothing rebinds the local, and the mark must still answer for both (Ruby: `NoMethodError` on the retried pass
# once `clear_separator` ran).
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

# Here the retried pass re-enters with a copy of `$;`, whose declared `Regexp` the entry's binding does not accept,
# so the local is rebound; the file writes `nil` to `$;` (Ruby: `NoMethodError` on the retried pass).
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
