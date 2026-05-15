# frozen_string_literal: true

# Cross-file dispatch through the synthesised methods Tier B
# emits from the `devise :*` calls in demo.rb. Without the plugin
# these would all fall through to `call.undefined-method` (or
# Dynamic[T] at best via the user-class fallback tier).
#
# Slice 3 floor (WD13): the synthesised readers return Dynamic[T];
# precise return-type promotion is the slice-6 ceiling. The
# substrate's job here is making sure the methods resolve at all.

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
