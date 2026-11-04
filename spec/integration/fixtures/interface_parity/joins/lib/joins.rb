# ADR-130 parity fixture: joins of a plugin-interface value. Under erasure each `dump_type` reads master's shape; with
# the carrier, each must read the same after the facet name is normalised (WD1's union merge). The nested shapes are
# review round 3's divergences.
class Joins
  def facet(a)
    Rigor.dump_type(a)
  end

  # Alone in its class, the facet survives the join.
  def mix(a, s, f)
    y = f ? a : s
    Rigor.dump_type(y)
  end

  def scalar(a, b, f)
    x = f ? a : b
    Rigor.dump_type(x)
  end

  def tup(a, b, f)
    t = f ? [a] : [b]
    Rigor.dump_type(t)
  end

  def shape(a, b, f)
    h = f ? { k: a } : { k: b }
    Rigor.dump_type(h)
    Rigor.dump_type(h.merge(z: 1))
  end

  def nested(a, b, f)
    n = f ? [{ k: [a] }] : [{ k: [b] }]
    Rigor.dump_type(n)
  end
end
