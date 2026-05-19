# frozen_string_literal: true

# Demo: rigor-sidekiq recognises every
# `Worker.perform_async` / `.perform_in` / `.perform_at` /
# `.perform_inline` call and validates argument count
# against the discovered `#perform`. Run with `bundle
# exec rigor check` from this directory.

# `WelcomeEmailWorker#perform(user_id, locale = "en")` →
# arity 1..2. Direct entry points forward all args.
WelcomeEmailWorker.perform_async(123)
WelcomeEmailWorker.perform_async(123, "ja")
WelcomeEmailWorker.perform_inline(123)

# Scheduled entry points consume the first arg as the
# schedule (a Time / Integer / duration). The remaining
# args are forwarded to `#perform`.
WelcomeEmailWorker.perform_in(60, 123)
WelcomeEmailWorker.perform_at(Time.now + 60, 123, "ja")

# `ReportWorker#perform(*report_ids)` → arity 0+.
ReportWorker.perform_async
ReportWorker.perform_async(1, 2, 3)
ReportWorker.perform_in(60, 1, 2)
