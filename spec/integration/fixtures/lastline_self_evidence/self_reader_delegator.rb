# rubocop:disable Style/SpecialGlobalVars
require "forwardable"
require "rigor/testing"

# Issue #1415 — a macro can put a Ruby reader in place under a literal name the file writes: `def_delegators` defines
# `LineHolder#gets` as a Ruby forwarder, which sets its own frame's `$_`. So no implicit-self `gets` in the file narrows
# `$_` (run with "a\nb\n" on standard input, `LineHolder.new.first` reads nil on Ruby 4.0.5), while `$stdin.gets` is
# `IO#gets`, which the forwarder does not reach, and still narrows (Ruby: the line).
class LineHolder
  extend Forwardable
  def_delegators :@io, :gets

  def initialize = (@io = $stdin)
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)

  def second = (Rigor::Testing.assert_type("String", $_) if $stdin.gets)
end
# rubocop:enable Style/SpecialGlobalVars
