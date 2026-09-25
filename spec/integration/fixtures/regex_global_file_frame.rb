# rubocop:disable Style/PerlBackrefs
require "rigor/testing"
include Rigor::Testing

# Issue #1358 — the file's top level is a frame of its own. A lambda made here that may match rebinds the top
# level's `$~` whenever it runs, so every call here may rebind it (Ruby: nil with `ARGV == ["a1"]`).
matcher = -> { "zz" =~ /(q)/ }
line = ARGV.join
if line =~ /(\d)/
  matcher.call
  assert_type("String?", $1)
end

# Control: a method body is a frame of its own, which the top level's lambda cannot reach (Ruby: `own_frame("a1")`
# reads "1").
def own_frame(str)
  if str =~ /(\d)/
    str.upcase
    assert_type("String", $1)
  end
end
# rubocop:enable Style/PerlBackrefs
