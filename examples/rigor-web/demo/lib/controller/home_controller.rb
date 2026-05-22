# frozen_string_literal: true

# A RigWeb controller.
#
# Notice what is NOT here: no base class, no `include`, no type
# annotation. The rigor-web plugin enforces the controller
# protocol — `#get` takes a `Rack::Request`, returns a
# `Rack::Response` — purely because this file lives under
# `lib/controller/`.
#
# Inside `#get`, `request` is analysed as a `Rack::Request`: the
# engine *provides* that type into the body, so `request.path_info`
# resolves against Rack's signature. A typo like
# `request.path_inf0` would surface as an ordinary core
# diagnostic, not something this plugin has to check for.
class HomeController
  def get(request)
    body = "Hello from #{request.path_info}"
    Rack::Response.new(body, 200)
  end
end
