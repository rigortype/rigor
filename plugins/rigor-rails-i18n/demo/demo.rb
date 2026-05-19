# frozen_string_literal: true

# Demo: rigor-rails-i18n recognises every literal-string
# `t(...)` / `I18n.t(...)` / `I18n.translate(...)` call and
# validates the key against `config/locales/*.yml`. Run
# with `bundle exec rigor check` from this directory.

# Define `t` so this file parses standalone (without
# Rails). The plugin only inspects call shape; it doesn't
# care that the runtime method here is a no-op.
def t(_key, **_options); end

# `users.welcome` exists in both `en` and `ja` and takes a
# `%{name}` placeholder.
t("users.welcome", name: "Alice")

# `users.bye` exists in both locales without any
# placeholders.
I18n.t("users.bye")

# `errors.messages.too_short` only exists in `en`. The
# call site passes `default:` so the missing-locale
# warning is suppressed.
t("errors.messages.too_short", count: 8, default: "too short")
