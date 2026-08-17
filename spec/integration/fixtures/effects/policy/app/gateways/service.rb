# frozen_string_literal: true

# The middle hop. Nothing here touches the world itself: what makes this method interesting is that the
# claim attached to `Acme::Http.get` one level down has to reach it, and then reach its own caller.
module Gateways
  class Service
    def place(id)
      Client.new.fetch(id)
    end
  end
end
