# frozen_string_literal: true

module REST
  # `REST::AccountSerializer` names `Account`, which the project's model index carries, so `object`
  # types as `Account` and its column readers resolve.
  class AccountSerializer < ActiveModel::Serializer
    attributes :id, :username, :display_name, :locked

    def display_name
      object.display_name
    end

    def locked
      object.locked
    end
  end
end
