# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"

# Issue #1415 — each class here is, or inherits from, a `CSV` subclass `relative_constant_writer.rb` makes by a
# constant write, whose `gets` is `CSV#gets`, an alias of its Ruby `shift`. So none narrows `$_` (Ruby 4.0.5, run
# with `relative_constant_writer.rb` required first and "a\n" on standard input: nil on each, since each reads
# its CSV's own input, never the caller's `$_`). The control: a plain class reads `Kernel#gets` (Ruby: "a\n").
class P::Q::Qux
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

module P
  class Sub < Q::Qux
    def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
  end
end

module R
  class Src < Inner::IO
    def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
  end
end

class Top < R::Inner::IO
  def first = (Rigor::Testing.assert_type("Dynamic[top]", $_) if gets)
end

class Plain
  def first = (Rigor::Testing.assert_type("String", $_) if gets)
end
# rubocop:enable Style/SpecialGlobalVars
