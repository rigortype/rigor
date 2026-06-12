require "rigor/testing"
include Rigor::Testing

# ADR-57 N5 — an implicit-self call to an *overridable* method whose base
# body returns a literal must NOT be adopted as a flow constant. The base
# return is the template-method *default*; a concrete subclass / includer
# overrides it, so folding it to a constant (and then folding a guard on
# it to always-truthy/falsey) is unsound. On such a hit the precise return
# degrades to `Dynamic[top]`. A method with NO discovered override folds
# exactly as before.
#
# Modelled on rgl's `module Graph; def directed?; false; end` template
# method, which `DirectedAdjacencyGraph` overrides to `true` — the entire
# rgl `flow.always-truthy-condition` warning set (2026-06-13 survey N5).

# --- Overridden method: base literal must not fold as a flow constant.

class Graph
  # The template default. The subclass below redefines this to `true`,
  # so an implicit-self `directed?` inside this class's own methods is
  # genuinely receiver-dependent and must not fold to `Constant[false]`.
  def directed? = false

  # Reads `directed?` via implicit self while checking THIS class body
  # (self typed as `Graph`). Before the gate this folds to
  # `Constant[false]` so the inferred return is `false` and a guard like
  # `unless directed?` folds to always-true (the rgl FP). With the gate
  # the self-call adoption degrades to `Dynamic[top]`.
  def probe_directed
    return :undirected unless directed?

    :directed
  end
end

class DirectedGraph < Graph
  # The override that makes `directed?` overridable in the project.
  def directed? = true
end

# `probe_directed` reads the implicit-self `directed?` whose adoption is
# now gated. Both branches of the `unless` stay live, so the return is the
# full `:undirected | :directed` union rather than a single dead-branch
# literal. (Before the gate `directed?` folded to `false`, pruning the
# `:directed` branch AND firing `flow.always-truthy-condition`.)
assert_type(":directed | :undirected", Graph.new.probe_directed)

# --- Non-overridden method: literal fold preserved.

class Final
  # No project class overrides `tag`, so the implicit-self read keeps
  # folding to the base literal (over-conservatism must not re-open a
  # Dynamic source for genuinely-final methods).
  def tag = :leaf

  def probe_tag = tag
end

# `tag` has no discovered override, so the self-call return folds to the
# base literal exactly as before the gate.
assert_type(":leaf", Final.new.probe_tag)
