ActiveRecord::Schema.define(version: 1) do
  create_table "users" do |t|
    t.string "email"
    t.string "name"
  end

  create_table "blogs" do |t|
    t.string "name"
  end

  create_table "posts" do |t|
    t.integer "blog_id"
    t.string "title"
  end
end
