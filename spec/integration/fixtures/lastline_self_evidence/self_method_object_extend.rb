# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
require_relative "ruby_line_reader"

# Issue #1415 — `method(:extend)` takes `main`'s `extend`, whose `call` puts `RubyReader` in `main`'s singleton class as
# `extend RubyReader` would, so no implicit-self reader in the file narrows `$_` (run with `read` as the first argument
# and "a\nb\n" on standard input: nil inside the loop, on Ruby 4.0.5).
method(:extend).call(RubyReader)

def lines
  while gets
    Rigor::Testing.assert_type("Dynamic[top]", $_)
  end
end

# The control: `$stdin.gets` is `IO#gets`, which the mixin does not reach (Ruby: the line).
def stdin_line = (Rigor::Testing.assert_type("String", $_) if $stdin.gets)
lines if ARGV.first == "read"
# rubocop:enable Style/SpecialGlobalVars
