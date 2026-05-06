# frozen_string_literal: true

# Run with the plugin from inside this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# rigor-deprecations is data-driven: every call site whose
# (receiver, method) matches a config entry surfaces as a
# :warning. No plugin code change is required to add a new
# deprecation rule — edit `.rigor.yml`.

# Matches `methods[0]` — receiver pinned to User.
User.find_by_sql("SELECT * FROM users WHERE id = 1")

# Matches `methods[1]` — no receiver pinned, any caller hits.
silence_warnings { puts "..." }

# Matches `methods[2]` — receiver pinned to ActiveRecord::Base.
ActiveRecord::Base.with_lock { puts "..." }

# Receiver text differs from the config — NOT a match. The
# plugin compares Prism's source slice to the config string,
# so `Account.find_by_sql` would not match the User-pinned
# entry.
Account.find_by_sql("SELECT * FROM accounts")

# Same method name, but no config entry — silent.
User.where(id: 1)
