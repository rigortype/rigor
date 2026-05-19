# frozen_string_literal: true

# Demo: rigor-factorybot recognises every entry method shape
# in the FactoryBot family. Run with `bundle exec rigor check`
# from this directory.

# Stub so `ruby demo.rb` doesn't fail at runtime — the plugin
# reads the call shape statically.
module FactoryBot
  def self.create(*, **) = nil
  def self.build(*, **) = nil
  def self.build_stubbed(*, **) = nil
  def self.attributes_for(*, **) = nil
  def self.create_list(*, **) = nil
end

# Recognised call shapes — each emits a `factory-call` info
# trace.
FactoryBot.create(:user)
FactoryBot.create(:user, name: "Alice", email: "alice@example.com")
FactoryBot.build(:post, title: "Hello", body: "...")
FactoryBot.build_stubbed(:post)
FactoryBot.attributes_for(:user)
FactoryBot.create_list(:user, 3, role: "admin")

# Legacy FactoryGirl alias is recognised too.
module FactoryGirl
  def self.create(*, **) = nil
end
FactoryGirl.create(:user, name: "Bob")
