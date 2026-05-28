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
