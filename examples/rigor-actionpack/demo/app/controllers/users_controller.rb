# frozen_string_literal: true

# Demo controller exercising the route-helper call shapes
# rigor-actionpack Phase 4 recognises:
#
# - bare helper (`users_path`)
# - helper with positional argument (`user_path(@user)`)
# - nested helper (`user_post_path(@user, @post)`)
# - namespaced helper (`admin_widget_path(@widget)`)
# - the `_url` form is recognised the same way
# - keyword-only options (`format: :json`) don't count
#   against arity
#
# The `redirect_to`, `link_to`, etc. shapes are pass-through:
# Rigor sees the `*_path` argument before it reaches the
# framework method.

class UsersController
  def index
    # Bare helper, info trace.
    redirect_to users_path
  end

  def show
    # Helper with positional argument.
    redirect_to user_path(@user, format: :json)
  end

  def nested
    # Nested resource helper — arity 2.
    redirect_to user_post_path(@user, @post)
  end

  def namespaced
    # Namespaced helper — arity 1.
    redirect_to admin_widget_path(@widget)
  end

  def url_form
    # _url form is recognised identically to _path.
    redirect_to user_url(@user)
  end
end
