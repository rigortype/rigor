# frozen_string_literal: true

# Demo: each call here triggers an error path
# rigor-factorybot Phase 1 (a) emits.

module FactoryBot
  def self.create(*, **) = nil
  def self.build(*, **) = nil
end

# `:usre` doesn't exist — should suggest `:user`.
FactoryBot.create(:usre)

# `:user` is real but `:rol` is not — should suggest `:role`.
FactoryBot.create(:user, name: "Alice", rol: "admin")

# `:post` exists but `:headline` isn't an attribute — should
# suggest `:title`.
FactoryBot.build(:post, headline: "Hello")
