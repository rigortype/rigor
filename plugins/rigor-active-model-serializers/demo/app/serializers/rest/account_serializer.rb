# frozen_string_literal: true

module REST
  # Every name this serializer reads off its resource — `username`, `locked` and `acct` from the
  # declarations, `display_name` from the body — is something `Account` answers, so `object` is
  # `Account` and the reads below it are checked.
  class AccountSerializer < ActiveModel::Serializer
    attributes :username, :locked, :acct, :display_name

    def display_name
      object.display_name
    end
  end
end
