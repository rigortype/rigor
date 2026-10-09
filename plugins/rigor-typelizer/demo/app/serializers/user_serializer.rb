# frozen_string_literal: true

# A subclass of the DSL base: typelizer lists it through `descendants`.
class UserSerializer < ApplicationSerializer
  typelize_from User
  typelize name: :string
end
