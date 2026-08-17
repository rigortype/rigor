# frozen_string_literal: true

# The entry point, two hops above the attributed call. The declared lane travels call edges exactly as
# the proven one does, so this method must read `≤ io.net.http` — not merely "and possibly more" — in the
# report and in the snapshot's `reach:` table.
module Controllers
  class Orders
    def create(id)
      Gateways::Service.new.place(id)
    end
  end
end
