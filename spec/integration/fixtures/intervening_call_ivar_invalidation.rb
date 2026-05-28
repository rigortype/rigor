require "rigor/testing"
include Rigor::Testing

# B2.2 — intervening method call ivar invalidation (ROADMAP §
# Future cycles / Type-language / engine; tracked in
# `docs/CURRENT_WORK.md` § "Flow-folding" — G2 case 2).
#
# Without the invalidation: `@performed = false; perform_request;
# if @performed` reads `@performed` as the local narrowing
# `Constant[false]` even though `perform_request` (a same-class
# method) writes `@performed = true`. The predicate folds to
# always-falsey and a false `flow.always-truthy-condition`
# (sense-inverted: "always falsey") fires.
#
# The fix: an implicit-self / `self.foo` call from within an
# instance method body could mutate any ivar, so each ivar's
# narrowed local binding is widened back to the class-ivar
# seed's union after the call returns. The predicate's
# subsequent read observes the seed (`Constant[false] |
# Constant[true]`) and no longer folds to a single Constant.
#
# Worked site: Mastodon
# `app/workers/activitypub/delivery_worker.rb` lines 34→39.

class DeliveryWorker
  def perform
    @performed = false
    perform_request
  ensure
    if @performed
      track_success
    else
      track_failure
    end
  end

  def perform_request
    @performed = true
  end

  def track_success
    "success"
  end

  def track_failure
    "failure"
  end
end
