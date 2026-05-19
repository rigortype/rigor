# frozen_string_literal: true

# Demo: rigor-pundit recognises every `authorize(...)` /
# `policy(...)` / `policy_scope(...)` call and validates
# the resolved policy class + (when present) the predicate
# method. Run with `bundle exec rigor check` from this
# directory.

# Stand-in implementations so this file parses standalone.
def authorize(_record, _action = nil); end
def policy(_record); end
def policy_scope(_scope); end

# `Post` is a constant; the plugin maps it to `PostPolicy`
# directly without needing inferred-type information.
authorize(Post, :show)
authorize(Post, :update?) # `:update?` and `:update` both work
authorize(Post, :destroy)

# `policy(...)` and `policy_scope(...)` get the same
# class-existence check.
policy(Comment)
policy_scope(Comment)

# Implicit-form `authorize(record)` (the action is taken
# from the controller at runtime). The plugin still
# validates the policy class.
authorize(Post)
