# frozen_string_literal: true

# Case 4: referenced NOWHERE. The only true candidate in this fixture.
class NeverUsed
  def dead = :dead
end
