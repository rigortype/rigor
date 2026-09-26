# rubocop:disable Style/SpecialGlobalVars, Style/GlobalStdStream
require "rigor/testing"
include Rigor::Testing

# Issue #1359 — a program that puts its own `gets` or `readline` in place through the `define_method` family runs
# that Ruby method, which sets its own frame's `$_`, so no reader of that name narrows `$_` in the file, whatever
# the receiver. `lastline_frame_local.rb`, which makes no such call, is the control that still narrows
# `$stdin.gets`. Each case cites what Ruby 4.0.5 answers with the patch alone in the file: nil, since a method
# starts with its own `$_` and the patched reader leaves it alone.

STDIN.define_singleton_method(:gets) { |*| "s\n" }
def stdin_singleton = (assert_type("Dynamic[top]", $_) if STDIN.gets)

$stdin.define_singleton_method(:readline) { |*| "r\n" }
def stdin_global_singleton = (assert_type("Dynamic[top]", $_) if $stdin.readline)

STDIN.singleton_class.define_method(:gets) { |*| "t\n" }
def singleton_class_definer = (assert_type("Dynamic[top]", $_) if STDIN.gets)

IO.define_method(:gets) { |*| "u\n" }
def io_definer = (assert_type("Dynamic[top]", $_) if File.open(__FILE__).gets)

# A computed name may be `gets` (Ruby: `patch(:gets)` then `computed_name` reads nil).
def patch(name) = IO.define_method(name) { |*| "v\n" }
def computed_name = (assert_type("Dynamic[top]", $_) if STDIN.readline)
# rubocop:enable Style/SpecialGlobalVars, Style/GlobalStdStream
