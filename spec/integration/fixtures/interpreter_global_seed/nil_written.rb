# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1362 — controls for the withheld declared `nil`: where this file writes `nil` to the global itself, a copy's
# `nil` is not the declaration's alone, and the report its writes earned before the join still fires.

$\ = nil
$/ = ","

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
# rubocop:enable Style/SpecialGlobalVars
