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

  # Absorption: master drops the `[a]` arm, which `[b | 1]` contains.
  def absorb(a, b, f, g)
    t = f ? [a] : [g ? b : 1]
    Rigor.dump_type(t)
  end

  # A call of a member the interface declares: the one row a dispatching carrier may change.
  def declared(a)
    Rigor.dump_type(a.to_str) # parity: declared-member
  end

  def put(set) = set.add(1)

  # Member order: master sorts `Dynamic[String] | Dynamic[top]`, and a facet must not move its member first.
  def order(a, f)
    names = ARGV.to_set
    put(names)
    names.each do |name|
      Rigor.dump_type(f ? a : name)
    end
  end
end
