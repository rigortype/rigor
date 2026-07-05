# frozen_string_literal: true

# RigWeb — a deliberately tiny routing layer, the virtual web framework the rigor-web example is built around.
#
# A `RigWeb` instance maps a request path to a `[ControllerClass, action]` handler. `#routes` dispatches an incoming
# `Rack::Request` to the matching controller and returns the controller's `Rack::Response`.
#
# RigWeb asks nothing structural of a controller — no base class, no `include`. The only requirement is behavioural: the
# action method must accept a `Rack::Request` and return a `Rack::Response`. The rigor-web plugin makes that unwritten
# requirement statically enforced for every class under `lib/controller/`.
class RigWeb
  def initialize
    @routes = {}
  end

  # Register a handler for GET requests to `path`. `handler` is a `[ControllerClass, action_symbol]` pair.
  def get(path, handler)
    @routes[path] = handler
  end

  # Dispatch a request to its registered controller.
  def routes(request)
    handler = @routes[request.path_info]
    return Rack::Response.new("Not Found", 404) if handler.nil?

    controller_class, action = handler
    controller_class.new.public_send(action, request)
  end
end
