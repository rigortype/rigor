# frozen_string_literal: true

# DO NOT run via `ruby errors_demo.rb` — analyse with
# `bundle exec rigor check` to see rigor-actionmailer's
# diagnostics.

# `UserMailer#welcome(user, locale = "en")` → arity 1..2.
# These call sites are wrong:

# Missing required user:
#   plugin.actionmailer.wrong-arity
UserMailer.welcome.deliver_now

# Too many positional args:
#   plugin.actionmailer.wrong-arity
UserMailer.welcome(:alice, "ja", :extra).deliver_later

# Calling an undefined action:
#   plugin.actionmailer.unknown-action
UserMailer.does_not_exist(:alice).deliver_now

# NOTE: `UserMailer#digest` has no view template under
# `app/views/user_mailer/digest.{html,text}.erb`, so the
# plugin emits a `plugin.actionmailer.missing-view`
# diagnostic anchored on the action's `def` line in
# `app/mailers/user_mailer.rb`.
