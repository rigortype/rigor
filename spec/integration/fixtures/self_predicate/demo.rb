require "rigor/testing"
include Rigor::Testing

# `predicate-if-true self is LoggedInUser` narrows the
# receiver local on the truthy edge of an `if`/`unless`
# predicate.
def visit
  user = User.new
  if user.logged_in?
    assert_type("LoggedInUser", user)
  else
    assert_type("User", user)
  end
end

# `assert-if-true self is AdminUser` narrows the receiver
# local on the truthy edge.
def admin_check
  user = User.new
  if user.admin?
    assert_type("AdminUser", user)
  else
    assert_type("User", user)
  end
end

# `assert self is RegisteredUser` narrows the receiver
# local unconditionally at the post-call scope.
def ensure_registered
  user = User.new
  user.ensure_registered!
  assert_type("RegisteredUser", user)
end
