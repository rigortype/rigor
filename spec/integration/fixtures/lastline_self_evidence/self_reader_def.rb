# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"

# Issue #1415 — `def self.gets` at the top level defines the reader on `main` itself, in Ruby, so no implicit-self
# `gets` in the file narrows `$_` (run with `read` as the first argument and "a\nb\n" on standard input: nil inside the
# loop, on Ruby 4.0.5). `$stdin.gets` is `IO#gets`, and still narrows (Ruby: the line).
def self.gets(*) = (@lines ||= ["ruby\n"]).shift

if ARGV.first == "read"
  while gets
    Rigor::Testing.assert_type("Dynamic[top]", $_)
  end
end

def stdin_line = (Rigor::Testing.assert_type("String", $_) if $stdin.gets)
# rubocop:enable Style/SpecialGlobalVars
