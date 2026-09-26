# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"

# Issue #1415 — `define_singleton_method(:gets)` at the top level defines the reader on `main` itself, as a Ruby block,
# so no implicit-self `gets` in the file narrows `$_` (run with `read` as the first argument and "a\nb\n" on standard
# input: nil inside the loop, on Ruby 4.0.5). The patch reaches `gets` on every receiver, while `$stdin.readline` is
# still `IO`'s and still narrows (Ruby: the line).
define_singleton_method(:gets) { |*| (@lines ||= ["ruby\n"]).shift }

if ARGV.first == "read"
  while gets
    Rigor::Testing.assert_type("Dynamic[top]", $_)
  end
end

def stdin_lines
  Rigor::Testing.assert_type("String", $_) while $stdin.readline
rescue EOFError
  nil
end
# rubocop:enable Style/SpecialGlobalVars
