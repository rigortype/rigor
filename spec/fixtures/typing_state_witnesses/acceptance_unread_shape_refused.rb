# ADR-129 G1' witness for :acceptance_unread_shape_refused (a sibling `acceptance_unread_shape_refused.rbs` is the
# fixture's signature). `G.i` has a tuple overload and an interface overload. An `Array[String]` argument has unknown
# arity, so the gradual overload pass re-asks the match with unread tuples refused, and the tuple's acceptance reads the
# refusal.
class G
  def self.probe(names)
    G.i(names)
  end
end
