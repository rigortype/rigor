# frozen_string_literal: true

require_relative "lib/runtime"
require_relative "app/models/user"
require_relative "app/models/post"
require_relative "app/models/comment"

# Run with the plugin from inside this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# rigor-activerecord reads `db/schema.rb` once (via
# Plugin::IoBoundary), discovers the AR models under
# `app/models/`, builds a model index, and validates each
# `Model.find` / `.find_by` / `.where` call against the
# resolved table's columns.

# ---- Recognised calls ----

User.find(1)                             # info: User.find returns User
User.find_by(email: "alice@example.com") # info: User.find_by(:email) on table users
User.find_by(name: "Alice", admin: true) # info: User.find_by(:name, :admin) on table users
User.where(admin: true)                  # info: User.where(:admin) on table users

Post.find(42)                            # info: Post.find returns Post
Post.where(published: true)              # info: Post.where(:published) on table posts
Post.where(user_id: 1, published: true)  # info: composite where with `t.references` column

Comment.find(99)                         # info
Comment.where(user_id: 1, post_id: 42)   # info: both `_id` columns from t.references
