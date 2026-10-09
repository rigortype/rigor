# frozen_string_literal: true

Alba.inflector = :active_support

user = User.new(1, "a", [Article.new("t", "b")], [Comment.new("c")])

# The block is `class_eval`ed on an anonymous Alba::Resource class: `attributes` is not a toplevel call.
inline = Alba.serialize(user) { attributes :id, :name }
Rigor.dump_type(inline)

hash = Alba.hashify(user) do
  attributes :id
end
Rigor.dump_type(hash)

resource = UserResource.new(user)
Rigor.dump_type(resource.serialize)
Rigor.dump_type(resource.to_h)
Rigor.dump_type(Admin::ReportResource.new(user).serialize)
