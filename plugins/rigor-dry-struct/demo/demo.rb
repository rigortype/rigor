# frozen_string_literal: true

# Tier C demo. Run from this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# The .rigor.yml in this directory enables the plugin and points
# signature_paths at the local sig/ stub for Dry::Struct. With
# Tier C active, the pre-pass synthesises `Address#city`,
# `Address#country`, `User#name`, `User#email`, and `User#admin`
# as instance readers. The `consumer.rb` file then dispatches
# `address.city` / `user.name` / etc. through the substrate's
# SyntheticMethodIndex below RBS dispatch (per WD13 — Dynamic[T]
# returns at the floor; precise return-type promotion is deferred
# to a later slice).
#
# Without the plugin the bare reader calls in `consumer.rb` would
# fall through to `call.undefined-method` (or `Dynamic[T]` via
# the user-class fallback tier).

class Address < Dry::Struct
  attribute :city, Types::String
  attribute :country, Types::String
  attribute? :postcode, Types::String
end

class User < Dry::Struct
  attribute :name, Types::String
  attribute :email, Types::String
  attribute :admin, Types::Bool
end
