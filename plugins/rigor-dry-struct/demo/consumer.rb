# frozen_string_literal: true

# Cross-file dispatch through the synthetic methods the substrate emits for the structs in demo.rb.
# Without the plugin these would fall through to `call.undefined-method` (or `Dynamic[T]` at best via
# the user-class fallback tier).
#
# The readers take their return type from the `Types::…` declaration when the `:dry_type_aliases` lookup
# resolves (so `address.city` is a `String`), and are untyped otherwise (WD13).

def greet_address(address)
  "#{address.city}, #{address.country}"
end

def admin_summary(user)
  return "regular: #{user.name}" unless user.admin

  "admin: #{user.name} <#{user.email}>"
end
