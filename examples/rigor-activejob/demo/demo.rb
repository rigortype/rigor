# frozen_string_literal: true

# Demo: rigor-activejob recognises every `Job.perform_later`
# / `.perform_now` / `.perform` call and validates arity
# against the discovered `#perform`. Run with `bundle exec
# rigor check` from this directory.

# `WelcomeEmailJob#perform(user_id, locale = "en")` →
# arity 1..2.
WelcomeEmailJob.perform_later(123)
WelcomeEmailJob.perform_later(123, "ja")
WelcomeEmailJob.perform_now(123)

# `ReportJob#perform(*report_ids)` → arity 0+ (rest).
ReportJob.perform_later
ReportJob.perform_later(1)
ReportJob.perform_later(1, 2, 3)
