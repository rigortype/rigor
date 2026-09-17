# frozen_string_literal: true

ActiveRecord::Schema[8.0].define(version: 1) do
  create_table "statuses", force: :cascade do |t|
    t.text "text", null: false
  end

  create_table "accounts", force: :cascade do |t|
    t.string "username", null: false
    t.string "display_name"
    t.boolean "locked", default: false, null: false
  end
end
