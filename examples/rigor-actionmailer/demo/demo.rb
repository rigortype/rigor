# frozen_string_literal: true

# Demo: rigor-actionmailer recognises every
# `Mailer.action(args).deliver_*` call and validates arity
# against the discovered action methods. Run with `bundle
# exec rigor check` from this directory.

# `UserMailer#welcome(user, locale = "en")` → arity 1..2.
UserMailer.welcome(:alice).deliver_now
UserMailer.welcome(:bob, "ja").deliver_later
UserMailer.with(user: :carol).welcome(:carol).deliver_now

# `UserMailer#reset_password(user)` → arity 1.
UserMailer.reset_password(:alice).deliver_now

# `UserMailer#digest(*entries)` → arity 0+ (rest).
UserMailer.digest.deliver_now
UserMailer.digest(:a, :b, :c).deliver_later
