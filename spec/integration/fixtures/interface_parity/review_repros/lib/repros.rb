# ADR-130 parity fixture: every finding the reviews of #2788 reproduced on an earlier draft, on synthetic
# `Rigor::Plugin::_Probe*` interfaces. Each was a false positive or a structural divergence on correct code; under the
# erasure baseline and with dispatch off each reads as master, and with dispatch on only the marked declared-member
# calls may differ. The join divergences of round 3 (`[a] | [b]`, `{ k: a } | { k: b }`) are in `joins`.
class Repros
  # Review 1: overload selection's imprecise pass must see the interface value as untyped.
  def mul(arr, x)
    Rigor.dump_type((arr * x).first)
  end

  def plus(x)
    Rigor.dump_type((1 + x).nan?)
  end

  def minus(x)
    Rigor.dump_type((5 - x).nan?)
  end

  def times(x)
    Rigor.dump_type((3 * x).nan?)
  end

  def pow(x)
    Rigor.dump_type((2**x).nan?)
  end

  # Review 1: the #1840 rejoin after a nil / String test.
  def rejoin_if(x)
    if x.nil?
      1
    elsif x.is_a?(String)
      2
    end
    Rigor.dump_type(x)
    x.to_str
  end

  def rejoin_case(x)
    case x
    when nil then 1
    when String then 2
    end
    Rigor.dump_type(x)
    x.to_str
  end

  # Review 2, severe 1: a join of two interface values, then a nil / String case.
  def r3(a, b, f)
    x = f ? a : b
    case x
    when nil then 1
    when String then 2
    end
    Rigor.dump_type(x)
    x + "z"
  end

  # The same with an untyped arm.
  def r3u(a, b, f)
    x = f ? a : b
    case x
    when nil then 1
    when String then 2
    end
    Rigor.dump_type(x)
    x + "z"
  end

  # Review 2, severe 2: a declared member called in a shape no overload takes (block-less `each`).
  def each_with_index(xs)
    Rigor.dump_type(xs.each)
    xs.each.with_index { |v, i| v + i }
    xs.each { |v| Rigor.dump_type(v) } # parity: declared-member => Integer
  end

  # The other side of the union rule: an interface value joined with a nominal keeps its facet, and a call declared
  # on both arms answers their join.
  def mix(a, s, f)
    y = f ? a : s
    Rigor.dump_type(y)
    Rigor.dump_type(y.to_str) # parity: declared-member => String
    case y
    when nil then 1
    when String then 2
    end
    y + "z"
  end

  # A control: the declared member resolves, and an undeclared one is silent.
  def facet(x)
    Rigor.dump_type(x)
    Rigor.dump_type(x.to_str) # parity: declared-member => String
    Rigor.dump_type(x.undeclared)
  end

  # Review 3: a block-pass that may be nil takes both shapes, whose returns disagree.
  def blockpass(xs, blk)
    Rigor.dump_type(xs.each(&blk))
    xs.each(&blk).with_index { |v, _i| v }
  end
end
