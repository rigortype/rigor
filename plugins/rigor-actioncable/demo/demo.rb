# frozen_string_literal: true

# Demo: rigor-actioncable recognises every
# `<Channel>.broadcast_to(...)` and
# `ActionCable.server.broadcast(stream_name, ...)` call
# and validates against the discovered channel index.
# Run with `bundle exec rigor check` from this directory.

# Stand-in `ActionCable.server.broadcast` so this file
# parses standalone.
module ActionCable
  def self.server
    @server ||= Server.new
  end

  class Server
    def broadcast(_stream, _data); end
  end
end

# `ChatChannel.broadcast_to(record, data)` —
# class-targeted broadcast. The plugin checks that
# `ChatChannel` is in the discovered index.
ChatChannel.broadcast_to(:my_room, message: "Welcome!")

# `ActionCable.server.broadcast("chat_room_5", data)` —
# stream-name-targeted broadcast. The plugin checks that
# `chat_room_5` was registered via `stream_from` in some
# discovered channel.
ActionCable.server.broadcast("chat_room_5", message: "Welcome!")
