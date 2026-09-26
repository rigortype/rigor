# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
require_relative "ruby_line_reader"

# Issue #1415 — `Kernel#readline` reads through `$stdin`: `ARGF.readline` hands an input that is not a `File` its own
# `readline`, so after the file binds `$stdin` to an object whose reader is Ruby's, an implicit-self `readline` does
# not narrow `$_` (run with `read` as the first argument, on Ruby 4.0.5: nil inside the loop). `Kernel#gets` sets `$_`
# to the line whatever `$stdin` holds, and still narrows (Ruby: "ruby\n").
$stdin = RubyReaderClass.new

def read_lines
  Rigor::Testing.assert_type("Dynamic[top]", $_) while readline
rescue EOFError
  nil
end

def get_lines
  while gets
    Rigor::Testing.assert_type("String", $_)
  end
end
# rubocop:enable Style/SpecialGlobalVars
