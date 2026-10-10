require "rigor/testing"

# Issue #1698 — `Shapes` is declared only in `sig/`. A class that includes it
# reads its constants by their bare names, after its lexical scopes and before
# the top level, as Ruby does.

class Drawing
  include Shapes

  def square = Square.new(2)
  def sides = SIDES
end

class Shadowing
  SIDES = "lexical"
  include Shapes

  def sides = SIDES
end

square = Drawing.new.square
Rigor.assert_type("Shapes::Square", square)
sides = Drawing.new.sides
Rigor.assert_type("Integer", sides)
shadowed = Shadowing.new.sides
Rigor.assert_type("\"lexical\"", shadowed)
