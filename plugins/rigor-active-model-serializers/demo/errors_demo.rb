# frozen_string_literal: true

# Intentionally ill-typed file. Deriving `object`'s model is what puts a checked type under every
# read below it: `object.text` is the `statuses.text` column, so it is a `String`, and a String
# method that does not exist is an error rather than a shrug.
class StatusSerializer < ActiveModel::Serializer
  def excerpt
    object.text.nickname
  end
end
