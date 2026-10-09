# frozen_string_literal: true

Alba.inflector = :active_support

user = User.new(1, "a", [Article.new("t", "b")], [Comment.new("c")])

# The block is `class_eval`ed on an anonymous Alba::Resource class: `attributes` is not a toplevel call.
inline = Alba.serialize(user) { attributes :id, :name }

hash = Alba.hashify(user) do
  attributes :id
end
puts inline, hash

UserResource.new(user).serialize
Admin::ReportResource.new(user).serialize
