# frozen_string_literal: true

require_relative "lib/validators"

# Run with the plugin from inside this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# rigor-pattern asks Rigor's type system whether each value
# argument below is provably a literal string. When it is,
# the configured regex runs at lint time:
#
# - Constant<String>             → exact match (info / error)
# - literal-string carrier       → "exact value not statically known" info
# - non-literal (variable, etc.) → silent (defer to runtime)

# Direct literals.
validate(:email, "user@example.com")    # info: matches
validate(:email, "not-an-email")        # error: does not match
validate(:uuid,  "a1b2c3d4-1111-2222-3333-444455556666") # info: matches
validate(:uuid,  "obviously-wrong") # error: does not match

# String concatenation — Rigor's LiteralStringFolding lifts
# all-Constant + chains so the plugin still gets a constant.
validate(:email, "user@example.com") # info: matches

# Unknown pattern name in config.
validate(:zip, "12345") # error: unknown-pattern

# Non-literal value — plugin stays silent and defers to
# runtime behaviour (no static guarantee possible).
external = ARGV.first || "user@example.com"
validate(:email, external)
