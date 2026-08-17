ActiveRecord::Schema.define(version: 1) do
  create_table "users" do |t|
    t.string "email"
    t.string "name"
  end
end
