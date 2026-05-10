# frozen_string_literal: true

# Sample factory file rigor-factorybot statically interprets.
# The plugin reads the call shape; nothing here is executed.

FactoryBot.define do
  factory :user do
    name { "Alice" }
    email { "alice@example.com" }
    role { "member" }
  end

  factory :post do
    title { "Hello, world" }
    body { "" }
    published { false }
  end
end
