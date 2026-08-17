# frozen_string_literal: true

# Two entries select this class. Which one binds it is the list order and nothing else, so the fixture
# carries one body and the spec varies the configuration around it.
module Ordered
  class Thing
    def touch
      File.read("thing")
    end
  end
end
