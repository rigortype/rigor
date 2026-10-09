# frozen_string_literal: true

# `extend` registers the class the same way `include` does.
class EventSerializer
  extend Typelizer::DSL

  typelize name: :string
end
