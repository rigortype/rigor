# frozen_string_literal: true

module REST
  # The name resolves to the real `Conversation` model and the resource is NOT one: `unread` and
  # `last_status` are absent from it, so the derivation declines and `object` stays `Dynamic`. This is
  # Mastodon's own `REST::ConversationSerializer`, whose resource is an `AccountConversation`.
  class ConversationSerializer < ActiveModel::Serializer
    attributes :id, :unread

    has_one :last_status, serializer: REST::StatusSerializer

    def id
      object.id.to_s
    end
  end
end
