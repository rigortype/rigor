# ADR-130 parity fixture: the overload-shape rule (WD3), one call per arm. A call no overload of the member takes reads
# as master reads a call on `Dynamic[top]`, so only the calls some overload takes are marked as declared-member calls.
class Shapes
  # Block presence, and a block-pass that may be nil.
  def block_shape(x, blk, sure)
    Rigor.dump_type(x.blockful { |i| i }) # parity: declared-member => Integer
    Rigor.dump_type(x.blockful)
    Rigor.dump_type(x.blockless) # parity: declared-member => Integer
    Rigor.dump_type(x.blockless { |i| i })
    Rigor.dump_type(x.optional_block) # parity: declared-member => Integer
    Rigor.dump_type(x.optional_block { |i| i }) # parity: declared-member => Integer
    Rigor.dump_type(x.overloaded) # parity: declared-member => Integer
    Rigor.dump_type(x.overloaded { |i| i }) # parity: declared-member => String
    # A possibly-nil block-pass: both shapes are taken, and only `agree`'s two returns agree.
    Rigor.dump_type(x.overloaded(&blk))
    Rigor.dump_type(x.agree(&blk)) # parity: declared-member => Integer
    Rigor.dump_type(x.blockful(&blk))
    # A block-pass that is never nil keeps the ordinary block shape, and so does `&:sym`.
    Rigor.dump_type(x.overloaded(&sure)) # parity: declared-member => String
    Rigor.dump_type(x.overloaded(&:to_s)) # parity: declared-member => String
    # A block literal binds its parameters only through an overload that takes the call.
    x.blk_pos { |s| Rigor.dump_type(s) }
    x.blk_pos(1) { |s| Rigor.dump_type(s) } # parity: declared-member => String
  end

  # Positional arity, rest parameters, keywords, and the shapes the AST cannot state.
  def arity(x, xs, opts)
    Rigor.dump_type(x.positional(1)) # parity: declared-member => Integer
    Rigor.dump_type(x.positional(1, 2)) # parity: declared-member => Integer
    Rigor.dump_type(x.positional)
    Rigor.dump_type(x.positional(1, 2, 3))
    Rigor.dump_type(x.rest(1, 2, 3, 4)) # parity: declared-member => Integer
    Rigor.dump_type(x.rest)
    Rigor.dump_type(x.keywords(1, key: 2)) # parity: declared-member => Integer
    Rigor.dump_type(x.keywords(1, key: 2, opt: 3)) # parity: declared-member => Integer
    Rigor.dump_type(x.keywords(1, opt: 3))
    Rigor.dump_type(x.keywords(1))
    Rigor.dump_type(x.hash_positional(1, k: 2)) # parity: declared-member => Integer
    Rigor.dump_type(x.blockless(k: 1))
    Rigor.dump_type(x.untyped_params(1, 2, k: 3)) # parity: declared-member => Integer
    Rigor.dump_type(x.positional(*xs))
    Rigor.dump_type(x.keywords(1, **opts))
  end

  # Inside a member `self` is the receiver. (RBS refuses `instance` in an interface.)
  def self_instance(x)
    Rigor.dump_type(x.me) # parity: declared-member => Dynamic[Rigor::Plugin::_ProbeShapes]
    Rigor.dump_type(x.me.blockless) # parity: declared-member => Integer
    Rigor.dump_type(x.same(1)) # parity: declared-member => Integer
  end

  # The interface's own type parameters bind from the value's type arguments; a defaulted one left unbound is untyped.
  def generics(box)
    Rigor.dump_type(box)
    Rigor.dump_type(box.get) # parity: declared-member => String
    Rigor.dump_type(box.other)
  end

  # Two interface values join to `Dynamic[top]` (WD1's merge), so nothing dispatches on the join.
  def union_receiver(left, right, f)
    v = f ? left : right
    Rigor.dump_type(v)
    Rigor.dump_type(v.name)
  end

  # An anonymous `&` forwards this method's own block, which may be absent.
  def anonymous_block(x, &)
    Rigor.dump_type(x.overloaded(&))
    Rigor.dump_type(x.agree(&)) # parity: declared-member => Integer
  end
end
