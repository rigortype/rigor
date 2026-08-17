# frozen_string_literal: true

# One segment deeper than `Policies::*` reaches. Its body exceeds every plausible bound, so silence here
# is evidence the glob stopped at the segment boundary rather than evidence of nothing happening.
module Policies
  module Admin
    class Edit
      def allow?(user)
        puts("admin #{user}")
        true
      end
    end
  end
end
