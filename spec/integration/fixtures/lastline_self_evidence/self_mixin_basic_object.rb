# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
require_relative "ruby_line_reader"

# Issue #1415 — a mixin on `BasicObject` counts as one on `main`, so no implicit-self reader in the file narrows `$_`.
# Ruby 4.0.5 still finds `Kernel#gets` first, since `Kernel` sits ahead of `BasicObject` (run with `read` as the first
# argument and "a\nb\n" on standard input: "a\n", then "b\n"), so this decline is conservative; `Kernel.include(M)`
# is the same.
BasicObject.include(RubyReader)

if ARGV.first == "read"
  while gets
    Rigor::Testing.assert_type("Dynamic[top]", $_)
  end
end

# The control: `$stdin.gets` still narrows (Ruby: the line).
def stdin_line = (Rigor::Testing.assert_type("String", $_) if $stdin.gets)
# rubocop:enable Style/SpecialGlobalVars
