# frozen_string_literal: true

module Broken
  # Intentionally ill-typed. Deriving `object`'s model is what puts a checked type under every read
  # below it: `object.username` is the `accounts.username` column, so it is a `String`, and a String
  # method that does not exist is an error rather than a shrug.
  class AccountSerializer < ActiveModel::Serializer
    attributes :username

    def excerpt
      object.username.nickname
    end
  end
end
