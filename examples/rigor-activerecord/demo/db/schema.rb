# frozen_string_literal: true

ActiveRecord::Schema[8.0].define(version: 20_260_507_000_000) do
  create_table "users", force: :cascade do |t|
    t.string  "name", limit: 100, null: false
    t.string  "email", null: false
    t.integer "age"
    t.boolean "admin", default: false, null: false
    t.timestamps
  end

  create_table "posts", force: :cascade do |t|
    t.string  "title", null: false
    t.text    "body"
    t.boolean "published", default: false, null: false
    t.references "user", foreign_key: true
    t.timestamps
  end

  create_table "comments", force: :cascade do |t|
    t.text "body"
    t.references "user", foreign_key: true
    t.references "post", foreign_key: true
    t.timestamps
  end
end
