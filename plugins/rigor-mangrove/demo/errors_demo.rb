# frozen_string_literal: true

# DO NOT run via `ruby errors_demo.rb` — analyse with
# `bundle exec rigor check` to see rigor-mangrove's effect.
#
# Each unwrap below resolves to `String` ONLY because
# rigor-mangrove instantiates the carrier generic at the call
# site. That makes the typo'd chained method a real
# `call.undefined-method` error. Without the plugin the unwraps
# are `untyped`, `untyped` swallows the typos, and these bugs
# ship silently.

def demo(ctx)
  session = Session.new

  # `String#uppercaze` does not exist — caught only because
  # `unwrap!` resolved to String.
  session.token.unwrap!.uppercaze

  # `String#lenght` typo — caught because `unwrap_in` resolved
  # to String.
  session.token.unwrap_in(ctx).lenght

  # `String#revrse` typo — caught because `unwrap_or` resolved
  # to String.
  session.cached_user.unwrap_or("guest").revrse
end
