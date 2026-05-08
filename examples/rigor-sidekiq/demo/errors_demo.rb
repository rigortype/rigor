# frozen_string_literal: true

# DO NOT run via `ruby errors_demo.rb` — analyse with
# `bundle exec rigor check` to see rigor-sidekiq's
# diagnostics.

# `WelcomeEmailWorker#perform(user_id, locale = "en")` →
# arity 1..2. These call sites are wrong:

# Missing required user_id:
#   plugin.sidekiq.wrong-arity
WelcomeEmailWorker.perform_async

# Too many positional args:
#   plugin.sidekiq.wrong-arity
WelcomeEmailWorker.perform_async(123, "ja", :extra)

# `perform_in` consumes the first arg as the schedule;
# zero-arg calls are missing-schedule:
#   plugin.sidekiq.missing-schedule
WelcomeEmailWorker.perform_in

# `perform_at(time)` schedules but forwards 0 args, so the
# required user_id is missing:
#   plugin.sidekiq.wrong-arity
WelcomeEmailWorker.perform_at(Time.now + 60)
