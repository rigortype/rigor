# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
require_relative "ruby_line_reader"

# Issue #1415 — a proc a `send` hands to `define_method` becomes a method of the receiver, run with the receiver as
# `self`, and the file may have written its body anywhere, so no implicit-self reader in the file narrows `$_` (run with
# `read` as the first argument and "a\nb\n" on standard input: nil inside the lambda, whose `gets` is
# `RubyReaderClass`'s, on Ruby 4.0.5).
reader = -> { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
RubyReaderClass.send(:define_method, :first, reader)

if ARGV.first == "read"
  RubyReaderClass.new.first
  # The control: `$stdin.gets` still narrows (Ruby: the line).
  Rigor::Testing.assert_type("String", $_) if $stdin.gets
end
# rubocop:enable Style/SpecialGlobalVars
