# frozen_string_literal: true

# DO NOT run via `ruby errors_demo.rb` — analyse with
# `bundle exec rigor check` to see rigor-actioncable's
# diagnostics.

module ActionCable
  def self.server
    @server ||= Server.new
  end

  class Server
    def broadcast(_stream, _data); end
  end
end

# Misspelled channel class — flagged with did-you-mean:
#   plugin.actioncable.unknown-channel
ChartChannel.broadcast_to(:my_room, message: "Hi")

# Stream name that no `stream_from` call registers in any
# discovered channel — flagged with did-you-mean:
#   plugin.actioncable.unknown-stream
ActionCable.server.broadcast("chat_room_42", message: "Hi")
