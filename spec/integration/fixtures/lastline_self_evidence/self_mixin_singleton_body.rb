# rubocop:disable Style/SpecialGlobalVars, Style/MixinUsage
require "rigor/testing"
require_relative "ruby_line_reader"

# Issue #1415 — an `include` in `class << self` at the top level mixes `RubyReader` into `main`'s singleton class, so no
# implicit-self reader in the file narrows `$_`. Run with `read` as the first argument and "a\nb\n" on standard input;
# each case cites what Ruby 4.0.5 answers.

class << self
  include RubyReader
end

# Ruby: nil, the line went to the Ruby reader's own frame.
if ARGV.first == "read"
  while gets
    Rigor::Testing.assert_type("Dynamic[top]", $_)
  end
end

def lines
  while gets
    Rigor::Testing.assert_type("Dynamic[top]", $_)
  end
end

# The control: `$stdin.gets` is `IO#gets`, which the mixin does not reach (Ruby: the line).
def stdin_line = (Rigor::Testing.assert_type("String", $_) if $stdin.gets)
# rubocop:enable Style/SpecialGlobalVars, Style/MixinUsage
