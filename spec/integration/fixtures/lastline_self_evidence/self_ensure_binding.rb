# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"

# Issue #1415 — an `ensure` clause keeps what a call the statement rules forget `$_` for did: `helper(b)` is handed the
# frame's `binding`, through which it reads a line into the frame's `$_` (Ruby 4.0.5 with "a\nb\n" on standard input:
# "b\n" after the clause), so `$_` stays unbound past the clause, and the `ensure`'s entry binding, the `String` the
# condition narrowed, is not put back. The eval of a String also declines every implicit-self reader in the file.
class Job
  def with_binding
    b = binding
    if $stdin.gets
      begin
        1
      ensure
        helper(b)
      end
      Rigor::Testing.assert_type("Dynamic[top]", $_)
    end
  end

  # The control: with no call that may read, the entry binding is put back (Ruby: "a\n").
  def plain
    if $stdin.gets
      begin
        1
      ensure
        nil
      end
      Rigor::Testing.assert_type("String", $_)
    end
  end

  def helper(b) = b.eval("$stdin.gets")
end
# rubocop:enable Style/SpecialGlobalVars
