# ADR-130 parity fixture: one method per site slice 1a routed through `Type::Combinator.untyped?` (WD2), each
# reaching its site with a `Rigor::Plugin` interface value. Under the erasure baseline the value is `Dynamic[top]`;
# with the carrier, the site must answer as it answers for `Dynamic[top]`, so a site spelled raw (testing the facet for
# `Top`, or comparing with `untyped`) shows here as a structural difference. `spec/integration/interface_parity_spec.rb`
# names which sites a raw spelling visibly breaks, and why the others cannot be told apart in `rigor check` output.
class Sites
  # `expression_typer.rb`, `nominal_range_for_endpoints`: an untyped endpoint contributes no element type.
  def range_endpoint(x)
    Rigor.dump_type(x..1)
  end

  # `expression_typer.rb`, `top_result?`: the ADR-84 memo stores an untyped result inside a recursive component.
  def top_result(x, n)
    Rigor.dump_type(ping(x, n))
  end

  def ping(x, n)
    n.zero? ? x : pong(x, n - 1)
  end

  def pong(x, n)
    n.zero? ? x : ping(x, n - 1)
  end

  # `statement_evaluator.rb`, `last_line_kept?`: an ensure clause keeps the `$_` it was entered with.
  def last_line(x)
    $_ = x

    Rigor.dump_type($_)
  end

  # `statement_evaluator.rb`, `join_break_scopes`: a loop binding that is untyped keeps it over a break arm.
  def loop_break(x, f, g)
    v = x
    while f
      v = x
      if g
        v = 1
        break
      end
    end
    Rigor.dump_type(v)
  end

  # `statement_evaluator.rb`, `for_iteration_element_type`: an untyped element asks `each`'s block parameters.
  def for_element(x, xs, each)
    for a in [x]
      Rigor.dump_type(a)
    end
    for b in xs
      Rigor.dump_type(b)
    end
    for c in each
      Rigor.dump_type(c) # parity: declared-member => Integer
    end
  end

  # `statement_evaluator.rb`, `join_block_break_bindings`: a block binding that is untyped keeps it over a break arm.
  def block_break(x, xs)
    v = x
    xs.each do |i|
      v = x
      if i > 1
        v = 1
        break
      end
    end
    Rigor.dump_type(v)
  end

  # `statement_evaluator.rb`, `merge_pattern_bindings`: an untyped binding from any member floors the name.
  def pattern_join(x, f)
    t = f ? [x] : [1]
    case t
    in [a]
      Rigor.dump_type(a)
    end
  end

  # `multi_target_binder.rb`, `join_member_bindings`: an untyped member binding is the whole answer.
  def multi_assign(x, f)
    t = f ? [x, 1] : [1, 2]
    a, b = t
    Rigor.dump_type(a)
    Rigor.dump_type(b)
  end

  # `clause_widening.rb`, `widen`: a rescue clause leaves an untyped binding alone.
  def clause_widening(x)
    v = x
    begin
      v = x
      Integer("1")
    rescue ArgumentError
      Rigor.dump_type(v)
      Rigor.dump_type(v.to_str) # parity: declared-member => String
    end
    Rigor.dump_type(v)
  end

  # `block_auto_splat.rb`, `join_types`: an untyped column is untyped.
  def auto_splat(x)
    [[x, 1], [1, 2]].each do |a, b|
      Rigor.dump_type(a)
      Rigor.dump_type(b)
    end
  end

  # `method_dispatcher.rb`, `rbs_result_untyped?`: an untyped RBS result crosses no dependency-source boundary.
  def boundary(x)
    Rigor.dump_type(wrap(x))
  end

  # `narrowing.rb`, `match_dynamic_kind`: an untyped `!~` operand keeps the match edge on the falsey branch.
  def match_kind(x)
    if x !~ /(a)/
      Rigor.dump_type($1)
    else
      Rigor.dump_type($1)
      Rigor.dump_type($~)
    end
    if x =~ /(b)/
      Rigor.dump_type(x)
    end
  end

  # `unknown_store_widening.rb`, `gradual_top?`: a stored untyped arm makes the element `Dynamic`.
  def unknown_store(x, xs)
    a = [x, "s"]
    xs.each { |i| a << i }
    Rigor.dump_type(a)
    h = { k: x }
    xs.each { |i| h[i] = x }
    Rigor.dump_type(h)
  end

  # `facet_distribution.rb`, `facet_members`: an untyped argument distributes over no facet.
  def facet_distribution(x)
    Rigor.dump_type(1.fdiv(x))
    Rigor.dump_type("s".center(x))
  end

  # `self_substitute.rb`, `projected_self`: untyped type arguments project no `self`.
  def self_substitute(xs)
    Rigor.dump_type(xs.tap { |a| })
    Rigor.dump_type(xs.select { |a| a })
  end

  # `imprecise_argument.rb`, `imprecise?`: an untyped argument keeps every overload it may reach.
  def imprecise(x)
    Rigor.dump_type(1 + x)
    Rigor.dump_type([1, 2].first(x))
    Rigor.dump_type(1.0 * x)
  end

  # `imprecise_argument.rb`, `untyped?` (read by overload selection): an untyped argument proves no value-pinning
  # parameter.
  def value_pinning(x)
    Rigor.dump_type(/a/.match?(x))
    Rigor.dump_type([1].fetch(x, nil))
  end

  # `rbs_dispatch.rb`, `no_static_evidence?`: an untyped argument binds no method type variable.
  def type_variable(x)
    Rigor.dump_type(wrap(x))
    Rigor.dump_type([x].push(1))
    Rigor.dump_type(Ident.ident(x).to_str)
  end

  # `method_dispatcher.rb`, the `EXPLICIT_UNTYPED` origin: an untyped RBS result is recorded as declared untyped.
  def explicit_untyped(x)
    v = wrap(x).first
    Rigor.dump_type(v)
    v.zork
  end

  def wrap(value) = [value]
end
