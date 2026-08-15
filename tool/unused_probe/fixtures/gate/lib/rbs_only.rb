# frozen_string_literal: true

# Case 3: referenced ONLY from sig/rbs_consumer.rbs, never from Ruby source.
class RbsOnlyReferenced
  def tag = :rbs
end
