# frozen_string_literal: true

# DO NOT run via `ruby errors_demo.rb` — analyse with
# `bundle exec rigor check` to see rigor-activejob's
# diagnostics.

# `WelcomeEmailJob#perform(user_id, locale = "en")` →
# arity 1..2. These call sites are wrong:

# Missing required user_id:
#   plugin.activejob.wrong-arity
WelcomeEmailJob.perform_later

# Too many positional args:
#   plugin.activejob.wrong-arity
WelcomeEmailJob.perform_later(123, "ja", :extra)

# `perform_now` shares the same arity rules:
WelcomeEmailJob.perform_now
