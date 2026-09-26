# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
require_relative "ruby_line_reader"

# Issue #1415 — a mixin into `Module` reaches every class and module object, so the implicit-self reader of a class or
# module method is `RubyReader#gets` (Ruby 4.0.5 with "a\nb\n" on standard input, `Config.first` and `Prompt.first`:
# nil). The control: an instance method's `self` is no module, and reads `Kernel#gets` (Ruby, `Config.new.second`: the
# line).
class Module
  include RubyReader
end

class Config
  def self.first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
  def second = (Rigor::Testing.assert_type("String", $_) if gets)
end

module Prompt
  def self.first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end
# rubocop:enable Style/SpecialGlobalVars
