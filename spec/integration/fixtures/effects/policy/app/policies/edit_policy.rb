# frozen_string_literal: true

# `namespace: "Policies::*"` selects exactly the classes ONE segment under `Policies` — `Policies::Edit`
# and not `Policies::Admin::Edit`, which is the depth rule the glob documentation states.
module Policies
  class Edit
    def allow?(user)
      puts("checking #{user}")
      true
    end
  end
end
