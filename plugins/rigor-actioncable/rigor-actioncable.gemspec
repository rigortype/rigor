# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-actioncable"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates ActionCable channel + broadcast call shape."
  spec.description = "Walks `app/channels/` for classes whose direct superclass is " \
                     "`ApplicationCable::Channel` (or `ActionCable::Channel::Base`), " \
                     "indexes their action methods + `stream_from` registrations, and " \
                     "validates `<Channel>.broadcast_to(...)` and " \
                     "`ActionCable.server.broadcast(stream_name, ...)` call sites for " \
                     "channel-class existence + (where literal) stream-name registration. " \
                     "No Rails runtime."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
