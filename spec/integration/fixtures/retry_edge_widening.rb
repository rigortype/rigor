require "rigor/testing"
include Rigor::Testing

# B2.1 — `retry` flow-edge widening (ROADMAP § Future cycles /
# Type-language / engine — "Flow-folding loop-mutation tracking
# (gaps G1 / G2)" / "retry flow edge"). Without the retry-edge
# fix, a counter pattern like `tries = 0; ...; rescue; tries +=
# 1; retry; end` observes `tries: Constant[0]` inside the begin
# body, and any `if tries > 100` predicate folds to
# always-falsey. The fix widens rebound locals / ivars in any
# retry-emitting rescue arm to their `Nominal` envelope so the
# re-entered begin body sees the post-retry type.
#
# Worked site: Mastodon `lib/mastodon/snowflake.rb#with_retries`.

def with_retries
  tries = 0

  begin
    yield
  rescue ArgumentError
    raise if tries > 100

    tries += 1
    retry
  end
end

# Ivar variant — same widening applies.
class Counter
  def call
    @attempts = 0

    begin
      yield
    rescue StandardError
      raise if @attempts > 10

      @attempts += 1
      retry
    end
  end
end

# The primary body's own rebind crosses the retry edge too: it
# can raise after any prefix of itself, so the retry re-enters
# with `tries` already incremented and `tries < 3` is false on
# the third attempt.
def with_counted_attempts
  tries = 0

  begin
    tries += 1
    raise ArgumentError, "flaky" if tries < 3
  rescue ArgumentError
    retry
  end
end

# The only increment sits on a branch that raises, so it never
# reaches the body's exit scope: only the scope at the raise
# carries it to the rescue arm's guard.
def with_flaky_branch(flaky)
  tries = 0

  begin
    if flaky
      tries += 1
      raise ArgumentError, "flaky"
    end
  rescue ArgumentError
    warn "retrying" if tries < 5
    retry
  end
end
