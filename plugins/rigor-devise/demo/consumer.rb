# frozen_string_literal: true

# Cross-file dispatch through the synthesised methods Tier B emits from the `devise :*` calls in
# demo.rb. Without the plugin these would all fall through to `call.undefined-method` (or Dynamic[T] at
# best via the user-class fallback tier).
#
# The substrate's job here is making sure the methods resolve at all; return types follow the module's
# RBS when it is authored, and are untyped otherwise.

def authenticate(user, password)
  return :no_password unless user.valid_password?(password)

  user.update_with_password(password: password)
  :ok
end

def remember_user(user)
  user.remember_me!
end

def trigger_recovery(user)
  user.send_reset_password_instructions
end

def lock_admin_after_failures(admin)
  admin.lock_access! if admin.failed_attempts > 5
end
