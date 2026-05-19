# frozen_string_literal: true

# Tier A demo. Run from this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# The .rigor.yml in this directory enables the plugin and
# points signature_paths at the local sig/ stub that mocks the
# subset of Sinatra::Base the demo touches. With Tier A active,
# bare identifiers inside each `get/post/...` block (params,
# redirect, halt) resolve through Sinatra::Base's RBS.
#
# Without Tier A the same blocks would type-check against the
# enclosing class body's Singleton[MyApp] self_type, where
# `redirect` and friends do not exist — every call would fall
# through to Dynamic[T] and the analyzer would lose track of
# the block's return type.

class MyApp < Sinatra::Base
  get "/" do
    "Hello, world"
  end

  get "/users/:id" do
    halt 404 unless params["id"]
    redirect "/users/#{params['id']}/profile"
  end

  post "/sessions" do
    halt 403 if params["forbidden"]
    "session created"
  end

  delete "/sessions/:id" do
    halt 404 unless params["id"]
    "session destroyed"
  end
end
