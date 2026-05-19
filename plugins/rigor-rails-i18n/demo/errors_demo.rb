# frozen_string_literal: true

# DO NOT run via `ruby errors_demo.rb` — analyse with
# `bundle exec rigor check` to see rigor-rails-i18n's
# diagnostics.

def t(_key, **_options); end

# Misspelled key — flagged with did-you-mean:
#   plugin.rails-i18n.unknown-key
t("users.welcom")

# Missing required interpolation:
#   plugin.rails-i18n.wrong-interpolation
t("users.welcome")

# Extra interpolation key not used by the locale's value:
#   plugin.rails-i18n.extra-interpolation
t("users.welcome", name: "Alice", extra: "unused")

# `errors.messages.blank` is only in `en`; this project's
# `configured_locales` is `[en, ja]` and there is no
# `default:`, so we get a missing-locale warning:
#   plugin.rails-i18n.missing-locale
t("errors.messages.blank")
