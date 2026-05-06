# frozen_string_literal: true

require_relative "lib/route_helpers"

# Run with the plugin from inside this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# rigor-routes reads `config/routes.yml` once (via
# Plugin::IoBoundary), caches the parsed RouteTable
# (--cache-stats shows the entry under `plugin.routes.route_table`),
# and validates each *_path / *_url call below against the
# table for existence + arity.

# ---- Recognised calls ----

puts users_path                  # GET /users
puts users_url                   # GET /users (URL flavour)
puts new_user_path               # GET /users/new
puts user_path(123)              # GET /users/:id
puts edit_user_path(456)         # GET /users/:id/edit
puts posts_path                  # GET /posts
puts post_path(7)                # GET /posts/:id
puts post_comment_path(7, 42)    # GET /posts/:post_id/comments/:id
