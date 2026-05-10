# frozen_string_literal: true

# Demo controller that triggers each error path
# rigor-actionpack Phase 4 emits:
#
# - unknown-helper (with did-you-mean) — `usres_path` typo.
# - wrong-helper-arity — `user_path` (arity 1) called with 0
#   args, and `user_post_path` (arity 2) called with 1.

class ErrorsController
  def typo
    # `usres_path` doesn't exist; should suggest `users_path`.
    redirect_to usres_path
  end

  def missing_arg
    # `user_path` requires 1 positional arg.
    redirect_to user_path
  end

  def too_few_for_nested
    # `user_post_path` requires 2 positional args.
    redirect_to user_post_path(@user)
  end
end
