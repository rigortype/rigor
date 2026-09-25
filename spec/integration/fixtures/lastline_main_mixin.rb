# rubocop:disable Style/SpecialGlobalVars, Style/MixinUsage
require "readline"
require "rigor/testing"

# Issue #1359 — a module mixed into `main` may bring a Ruby reader: after `include Readline`, `readline` is
# Reline's Ruby method, which sets its own frame's `$_`, so no implicit-self reader in this file narrows it. Run it
# with `read` as the first argument to read standard input; each case cites what Ruby 4.0.5 answers.
include Readline

if ARGV.first == "read"
  # Ruby: nil, however many lines Reline returns.
  while readline("> ", true)
    Rigor::Testing.assert_type("Dynamic[top]", $_)
  end
  # Ruby: the line; the mixin is not traced to show `gets` is still `Kernel`'s.
  Rigor::Testing.assert_type("Dynamic[top]", $_) if gets
end
# rubocop:enable Style/SpecialGlobalVars, Style/MixinUsage
