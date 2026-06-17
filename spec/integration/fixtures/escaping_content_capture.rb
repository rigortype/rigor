require "rigor/testing"
include Rigor::Testing

# ADR-57 slice 2 (ADR-56 mechanisms 2 / 8 extended to escaping blocks).
# An escaping / unknown block that CONTENT-mutates a captured outer local
# previously left the local's seed precision intact, so `options[:k] = v`
# inside an `OptionParser#on` block (an escaping call) or `s << x` inside a
# stored proc kept the constant `{}` / `""` seed — unsoundly precise, since
# the block may run later and add anything. The fix widens the mutated
# local to its bare-collection floor.

# An opaque receiver makes the block `:unknown` (treated as escaping). A
# captured Hash content-mutated in the block must widen to the
# `Hash[untyped, untyped]` floor — NOT survive as the empty `{}` whose
# `[:format]` read would unsoundly fold to a constant / nil.
def sink = [].sample

options = {}
sink.on("--format F") { |v| options[:format] = v }
assert_type("Hash[Dynamic[top], Dynamic[top]]", options)

# A captured String append in an escaping block widens to `String`, not the
# `""` constant (whose `.empty?` would unsoundly fold to `true`).
buffer = ""
sink.each_line { |line| buffer << line }
assert_type("String", buffer)

# A captured Array append widens to `Array[Dynamic[top]]`.
collected = []
sink.subscribe { |item| collected << item }
assert_type("Array[Dynamic[top]]", collected)

# A capture content-mutated in a block NESTED inside another escaping block
# (the canonical `OptionParser.new do |opts| opts.on { o[:k] = v } end`
# idiom) must also widen: the mutation lives at capture depth >= 2 from the
# outer block, but the slice-2 collector must still find it.
nested = {}
sink.tap { |outer| outer.on("--x V") { |v| nested[:x] = v } }
assert_type("Hash[Dynamic[top], Dynamic[top]]", nested)

# A read-only capture in an escaping block is untouched: `seen` is only
# read, never content-mutated, so it keeps its precise empty-hash type.
seen = {}
sink.tap { |_| seen.size }
assert_type("{}", seen)

# The exact CLI parse_options idiom: the block is attached to
# `OptionParser.new` but the OUTER call node is the chained `.parse!`. The
# mutated captures live in `opts.on { ... }` blocks nested inside it.
chained = { format: "text" }
OptionParser.new do |opts|
  opts.on("--format=F") { |v| chained[:format] = v }
end.tap { |_| nil }
assert_type("Hash[Dynamic[top], Dynamic[top]]", chained)

# The cross-method-boundary variant: a content-mutable local passed to a
# toplevel helper that RETURNS an object holding an escaping closure over it
# (the `build_option_parser(options).parse!` idiom). The helper resolves to a
# user def whose `options` parameter is escape-mutated inside a nested
# `opts.on { options[:k] = v }` block; the caller floors the argument it
# passed, even though the helper call sits in the receiver position of the
# chained `.tap`.
def build_opts(options)
  sink.tap { |p| p.on("--format=F") { |v| options[:format] = v } }
end

handed = { mode: "print" }
build_opts(handed).tap { |_| nil }
assert_type("Hash[Dynamic[top], Dynamic[top]]", handed)

# The CLI `parse_options` idiom: the escape-mutating block hangs off
# `OptionParser.new` (RECEIVER position) AND its body is a bare self-call
# `define_opts(opts, routed)` that escape-mutates the `routed` argument inside
# ITS nested `opts.on { routed[:k] = v }` blocks. The capture is mutated through
# TWO indirections — a receiver-chain block plus a callee boundary — so neither
# the direct content-mutation collector (the block body holds no `routed[:k] =
# v`) nor the call-site receiver-chain floor (`define_opts` is not in the outer
# `.parse!` chain) catches it alone. Without the floor, `routed` keeps its
# literal-false seed and the caller's `routed[:mutation]` guard folds to an
# always-falsey constant.
def define_opts(opts, routed)
  opts.on("--mode=M") { |v| routed[:mode] = v }
end

routed = { mode: "print", mutation: false }
OptionParser.new { |opts| define_opts(opts, routed) }.parse!([])
assert_type("Hash[Dynamic[top], Dynamic[top]]", routed)
