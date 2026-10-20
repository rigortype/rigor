# frozen_string_literal: true

# Issue #2002 — a module String includes still keeps its type on the `/re/ === x` match edge when it declares `to_str`:
# here the project's signature reopens `Comparable` with one, so a `Comparable` value converts. Ruby:
# with `module Comparable; def to_str = "12"; end`, `/\d/ === Class.new { include Comparable }.new` is true.
module Comparable
  def to_str = "12"
end

class ReopenProbe
  def comparable_subject(s)
    assert_type("Comparable", s) if /\d/ === s
  end
end
