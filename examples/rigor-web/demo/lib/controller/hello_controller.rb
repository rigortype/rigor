# frozen_string_literal: true

# A second RigWeb controller. Reads a query parameter off the request and echoes it back in the response body.
class HelloController
  def get(request)
    name = request.params.fetch("name", "world")
    Rack::Response.new("Hello, #{name}!", 200)
  end
end
