# frozen_string_literal: true

# DO NOT run via `ruby errors_demo.rb` — analyse with
# `bundle exec rigor check` to see rigor-rails-routes'
# diagnostics.

def widgts_path = "/widgets"
def user_path(*_args) = "/users/x"
def admin_widget_path = "/admin/widgets"
def usres_path = "/usres"

# Typo (close to `widgets_path` via `admin_widgets_path`):
#   plugin.rails-routes.unknown-helper
#   no route helper `widgts_path` (did you mean ...)
puts widgts_path

# Wrong arity — `user_path` expects 1 arg (the :id), got 3:
#   plugin.rails-routes.wrong-arity
puts user_path(1, 2, 3)

# Wrong arity — `admin_widget_path` expects 1 arg, got 0:
#   plugin.rails-routes.wrong-arity
puts admin_widget_path

# Typo with did-you-mean:
#   plugin.rails-routes.unknown-helper (suggesting users_path)
puts usres_path
