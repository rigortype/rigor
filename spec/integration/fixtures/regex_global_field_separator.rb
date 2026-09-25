# rubocop:disable Style/PerlBackrefs, Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1365 — `split` without a separator splits on `$;`, and this file writes a Regexp there, so such a split runs
# a match and rebinds `$~`, as a statement and in an operand (Ruby: nil for each with `str = "a1"` and `row = "a,b"`
# once `use_regexp_separator` has run). A file that never writes `$;` keeps the narrowing across `row.split`
# (`regex_global_narrowing.rb`).
def use_regexp_separator = ($; = /(q)/)

def field_split(str, row)
  if str =~ /(\d+)/
    row.split
    assert_type("String?", $1)
  end
end

def field_split_limit(str, row)
  if str =~ /(\d+)/
    row.split(nil, 2)
    assert_type("String?", $1)
  end
end

def field_split_operand(str, row)
  if str =~ /(\d+)/
    [row.split]
    assert_type("String?", $1)
  end
end
# rubocop:enable Style/PerlBackrefs, Style/SpecialGlobalVars
