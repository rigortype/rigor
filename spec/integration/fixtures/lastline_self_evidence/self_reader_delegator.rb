# rubocop:disable Style/SpecialGlobalVars
require "forwardable"
require "rigor/testing"

# Issue #1415 — a macro can put a Ruby reader in place under a literal name the file writes: `def_delegators` defines
# `LineHolder#gets` as a Ruby forwarder, which sets its own frame's `$_`. So no implicit-self `gets` in the file narrows
# `$_` (run with "a\nb\n" on standard input, `LineHolder.new.first` reads nil on Ruby 4.0.5). Since #2793 the delegator
# also counts as the program defining `gets` (`BlockCallTiming.project_defines_anywhere?`), as a `def gets` in the class
# does: a `LineHolder` bound to `$stdin` would run the forwarder, which sets its own frame's `$_`, so `$stdin.gets`
# no longer narrows either (Ruby: the line here, but nothing in the file proves `$stdin` is an `IO`). `$stdin.readline`,
# a name no macro of the file defines, is `IO#readline` and still narrows (Ruby: the line).
class LineHolder
  extend Forwardable
  def_delegators :@io, :gets

  def initialize = (@io = $stdin)
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)

  def second = (Rigor::Testing.assert_type("Dynamic[top]", $_) if $stdin.gets)
  def third = (Rigor::Testing.assert_type("String", $_) if $stdin.readline)
end
# rubocop:enable Style/SpecialGlobalVars
