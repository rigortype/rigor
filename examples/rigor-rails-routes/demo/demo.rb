# frozen_string_literal: true

# Demo: rigor-rails-routes recognises every helper Rails would
# generate from `config/routes.rb` (statically — no Rails
# runtime). Run with `bundle exec rigor check` from this
# directory.

# Stubs so `ruby demo.rb` doesn't fail at runtime — the
# plugin reads the call shapes statically and doesn't care
# about the runtime values.
def root_path = "/"
def users_path = "/users"
def user_path(_id) = "/users/x"
def new_user_path = "/users/new"
def edit_user_path(_id) = "/users/x/edit"
def user_posts_path(_user_id) = "/users/x/posts"
def user_post_path(_user_id, _id) = "/users/x/posts/y"
def profile_path = "/profile"
def admin_widgets_path = "/admin/widgets"
def admin_widget_path(_id) = "/admin/widgets/x"
def about_path = "/about"
def about_url = "https://example.invalid/about"

# All recognised helpers. Each line surfaces an info diagnostic
# from rigor-rails-routes naming the HTTP method + path.
puts root_path
puts users_path
puts user_path(1)
puts new_user_path
puts edit_user_path(1)
puts user_posts_path(1)
puts user_post_path(1, 2)
puts profile_path
puts admin_widgets_path
puts admin_widget_path(1)
puts about_path
puts about_url
