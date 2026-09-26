# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
require "stringio"
require_relative "ruby_line_reader"

# Issue #1415 — a class body that reopens a core class and mixes a module into it reaches every class below it:
# `NumberedFile < File < IO` reads `RubyReader#gets` first (Ruby 4.0.5, `NumberedFile.new(__FILE__).first`: nil). The
# control: `StringIO` is no `IO`, and its C reader still sets `$_` (Ruby, `BufferSource.new("s1\n").first`: "s1\n").
class IO
  prepend RubyReader
end

class NumberedFile < File
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class BufferSource < StringIO
  def first = (Rigor::Testing.assert_type("String", $_) if gets)
end
# rubocop:enable Style/SpecialGlobalVars
