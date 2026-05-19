# frozen_string_literal: true

# Sample ActionCable channel — rigor-actioncable
# discovers this class because its direct superclass is
# `ApplicationCable::Channel` (one of the configured
# `channel_base_classes`).

module ApplicationCable
  class Channel
    # Stand-in base class so this file parses standalone.
    # rigor-actioncable doesn't care whether the base class
    # is declared here or anywhere else — it only matches
    # by name against `channel_base_classes`.
    def self.broadcast_to(*); end

    def stream_from(_name); end
    def stream_for(_record); end
  end
end

class ChatChannel < ApplicationCable::Channel
  def subscribed
    stream_from "chat_room_5"
  end

  def speak(data)
    # Server-side action method — invoked from JS via
    # `subscription.perform("speak", data)`.
    data
  end

  def whisper(data)
    data
  end
end
