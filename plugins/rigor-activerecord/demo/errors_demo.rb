# frozen_string_literal: true

require_relative "lib/runtime"
require_relative "app/models/user"
require_relative "app/models/post"

# Intentionally ill-typed file — demonstrates the diagnostics
# rigor-activerecord emits for unknown columns and arity
# mistakes. DO NOT run via `ruby errors_demo.rb` — the runtime
# stubs accept anything; rigor check is what catches these.

# Unknown column with a close did-you-mean suggestion.
User.where(emial: "alice@example.com")
# error: User.where(emial: ...) references unknown column `emial`
#        on table `users` (did you mean `:email`?)

# Unknown column on find_by.
User.find_by(usrname: "alice")
# error: unknown column `usrname` on table `users` (did you mean `name`? — distance 3 might miss)

# Unknown column with no close match.
Post.where(some_unrelated_column: 1)

# Arity error on find.
User.find
# error: User.find expects at least 1 argument, got 0

# Mixing valid and invalid keys — only the invalid one fires.
Post.where(title: "hello", invented_column: true)
