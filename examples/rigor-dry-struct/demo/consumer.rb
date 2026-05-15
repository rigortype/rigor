# frozen_string_literal: true

# Cross-file dispatch through the synthetic methods the substrate
# emits for the structs in demo.rb. Without the plugin these
# would fall through to `call.undefined-method` (or `Dynamic[T]`
# at best via the user-class fallback tier).
#
# Slice 2c floor (WD13): the synthetic readers return `Dynamic[T]`;
# precise return-type promotion (so `address.city` returns `String`
# from the `Types::String` declaration) is the ceiling, deferred
# to a later slice routing through ADR-13's resolver chain.

def greet_address(address)
  "#{address.city}, #{address.country}"
end

def admin_summary(user)
  return "regular: #{user.name}" unless user.admin

  "admin: #{user.name} <#{user.email}>"
end
