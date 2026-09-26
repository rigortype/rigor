# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1437 — the nil-bearing separators (`$/`, `$,`, `$;`, `$\`, `$-0`, `$-F`, `$-i`) are not joined with their
# declared type yet: each still reads the union of this file's writes to it, as before #1362, so every shape here
# reports exactly what it reported before. The folds below are that behaviour, still on; flip each to QUIET-1362 when
# #1437 joins the separators. Each method runs with whatever the command line or another file set last.

$/ = ","
$, = "-"
$\ = "\n"
$-0 = "\n"
$-i = ".bak"

# Ruby: 1.
def plain_copy
  sep = $/
  assert_type('","', sep)
  sep.length # QUIET-1362
end

# Ruby: returns early under `ruby -0777`; the fold reads the file's write alone. Flip when #1437 lands.
def guarded_unless
  return unless $/ # FIRES-1362 flow.always-truthy-condition

  sep = $/
  sep.length
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

# Flip when #1437 lands: another file may set `$, = nil`.
def output_separator_in_condition
  if $, # FIRES-1362 flow.always-truthy-condition
    sep = $,
    sep.size
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

def copy_of_copy
  sep = $,
  copy = sep
  copy.size # QUIET-1362
end

def parenthesised_copy
  sep = ($,)
  sep.size # QUIET-1362
end

def conditional_value(flag)
  sep = flag ? $/ : ";"
  sep.length # QUIET-1362
end

def default_value(given)
  sep = given || $/
  sep.length # QUIET-1362
end

def asymmetric_join(flag)
  sep = ";"
  sep = $/ if flag
  sep.length # QUIET-1362
end

def method_result
  sep = $,.dup
  sep.size # QUIET-1362
end

def container_element = [$/].each { |sep| sep.length } # QUIET-1362

# Controls: a `nil` the method binds itself still reports.
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
# rubocop:enable Style/SpecialGlobalVars
