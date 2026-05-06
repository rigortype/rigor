# frozen_string_literal: true

# Intentionally ill-typed file — demonstrates the diagnostics
# rigor-routes emits for unknown helpers and arity mismatches.
# DO NOT run via `ruby errors_demo.rb` — the unknown helpers
# would NoMethodError at runtime. Run `rigor check` instead.

# Unknown route helpers (with did-you-mean suggestions).
unknown_widget_path
useres_path

# Wrong arity.
user_path                  # `:id` is required
user_path(1, 2)            # extra argument
edit_user_path             # missing `:id`
post_comment_path(7)       # only one of (`:post_id`, `:id`)
