# frozen_string_literal: true

# Valid Mangrove usage. With rigor-mangrove loaded, each unwrap
# resolves to the carrier's first type argument (here `String`),
# so the chained calls below dispatch against the real type and
# stay clean.
#
# Run:  bundle exec rigor check
#
# Drop `rigor-mangrove` from .rigor.yml and the unwraps fall back
# to `untyped`; the chains stay quiet here, but the typos in
# errors_demo.rb then go unnoticed.

def demo(ctx)
  session = Session.new

  # Result#unwrap! → OkType (String)
  puts session.token.unwrap!.upcase

  # Result#unwrap_in(ctx) → OkType (String) — the early-return form
  puts session.token.unwrap_in(ctx).length

  # Option#unwrap_or(default) → InnerType (String)
  puts session.cached_user.unwrap_or("guest").reverse
end
