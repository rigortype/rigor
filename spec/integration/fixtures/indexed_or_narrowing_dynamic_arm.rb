require "rigor/testing"
include Rigor::Testing

# Issue #544 — the decline side of `receiver[key] ||= default` narrowing. `options` carries an
# untracked (Dynamic) arm — a caller can pass `count: 1`, which the `||=` KEEPS — so recording the
# default alone would invent a fact and fold the reachable `== 1` branch away
# (`flow.always-truthy-condition` fired on mail's TestRetriever#find exactly this way).
def half_tracked(given = nil)
  options = given ? Hash[given] : {}
  options[:count] ||= :all
  options[:what] ||= :first
  items = [1, 2, 3]
  items.reverse! if options[:what] == :last
  if options[:count] == 1
    :one
  else
    :many
  end
end
