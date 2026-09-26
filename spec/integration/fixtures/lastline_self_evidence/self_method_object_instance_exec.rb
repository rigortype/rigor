# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
require_relative "ruby_line_reader"

# Issue #1415 — `method(:instance_exec)` runs its block with the receiver as `self`, as `instance_exec` itself does, and
# so does `instance_method(:instance_exec)` bound to one, so no implicit-self reader in the file narrows `$_` (run with
# `read` as the first argument and "a\nb\n" on standard input: nil in each block, whose `gets` is `RubyReaderClass`'s,
# on Ruby 4.0.5).
if ARGV.first == "read"
  RubyReaderClass.new.method(:instance_exec).call { Rigor::Testing.assert_type("Dynamic[top]", $_) if gets }
  BasicObject.instance_method(:instance_exec).bind_call(RubyReaderClass.new) do
    Rigor::Testing.assert_type("Dynamic[top]", $_) if gets
  end
  # The control: `$stdin.gets` still narrows (Ruby: the line).
  Rigor::Testing.assert_type("String", $_) if $stdin.gets
end
# rubocop:enable Style/SpecialGlobalVars
