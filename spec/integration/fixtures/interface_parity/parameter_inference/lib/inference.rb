# ADR-130 parity fixture: ADR-67 WD3's inferred-parameter override (`statement_evaluator.rb`, `untyped_binding?`). A
# parameter declared with a `Rigor::Plugin` interface binds `untyped` under erasure, so the call-site inference
# overrides it; with the carrier it must be overridden alike (WD2: "ADR-67 WD3 overrides an interface parameter").
class Inference
  def take(x)
    Rigor.dump_type(x)
  end

  def caller_side
    take("s")
  end
end
