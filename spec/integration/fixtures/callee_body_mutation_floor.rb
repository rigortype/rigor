require "rigor/testing"
include Rigor::Testing

# ADR-56 / ADR-57 callee-argument floor extended to a callee that mutates its
# parameter's content DIRECTLY in the method body (not inside a block).
#
# `absorb` fills the `declaration` Hash it is handed (`declaration[:prefix] =
# …`, a top-level `[]=`); the caller passes its own `declaration` into that
# helper from inside a `statements.each { … }` block. The pre-existing
# callee-argument floor only recognised a parameter mutated inside a block in
# the callee body, so `declaration` kept its empty-literal seed
# (`{ prefix: [], versions: [] }`). A later
# `declaration[:prefix].empty? && declaration[:versions].empty?` then folded
# both empty-`Tuple` reads to `Constant[true]` and the `&&` to a constant,
# firing a spurious `flow.always-truthy-condition`. This is the
# rigor-rails-routes Grape API discoverer false positive.
#
# The floor now also fires for the direct-in-body mutation, so the read no
# longer folds. Always-safe: it only forgets a literal-shape fact the mutation
# no longer justifies.
class Discoverer
  def record(statements)
    declaration = { prefix: [], versions: [] }
    statements.each { |statement| absorb(statement, declaration) }
    return :empty if declaration[:prefix].empty? && declaration[:versions].empty?

    declaration
  end

  def absorb(node, declaration)
    declaration[:prefix] = [node]
    declaration[:versions] << node
  end
end
