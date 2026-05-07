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

# v0.1.1 Track 1 slice 3 — `predicate-if-*` self narrowing
# now covers three receiver shapes beyond the local-variable
# case already supported in v0.1.0.
class User
  def setup
    @buddy = User.new
  end

  # InstanceVariableReadNode receiver: `@buddy.logged_in?`
  # narrows `@buddy` itself on each edge. `LoggedInUser < User`
  # so the intersection on the truthy edge is `LoggedInUser`.
  def greet_buddy
    if @buddy.logged_in?
      assert_type("LoggedInUser", @buddy)
    else
      assert_type("User", @buddy)
    end
  end

  # Implicit self (no receiver): `logged_in?` inside an
  # instance method body narrows `scope.self_type` on each
  # edge. `assert_type(_, self)` reads `scope.type_of(self)`,
  # which returns the (narrowed) `self_type`. `User#logged_in?`
  # carries `predicate-if-true self is LoggedInUser`, so the
  # truthy edge sees `User ∩ LoggedInUser = LoggedInUser`.
  def greet
    if logged_in?
      assert_type("LoggedInUser", self)
    else
      assert_type("User", self)
    end
  end
end
