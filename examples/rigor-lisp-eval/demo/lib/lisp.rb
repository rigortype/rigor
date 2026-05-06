# frozen_string_literal: true

# Tiny S-expression-style interpreter the plugin types
# statically. The runtime body is intentionally
# straightforward; the demo's value is what `rigor check`
# says about callers, not the runtime semantics here.
module Lisp
  module_function

  def eval(expr)
    case expr
    when Integer, Float, true, false
      expr
    when Array
      raise ArgumentError, "empty form" if expr.empty?

      op, *args = expr
      case op
      when :+ then Lisp.eval(args[0]) + Lisp.eval(args[1])
      when :- then Lisp.eval(args[0]) - Lisp.eval(args[1])
      when :* then Lisp.eval(args[0]) * Lisp.eval(args[1])
      when :/ then Lisp.eval(args[0]) / Lisp.eval(args[1])
      when :< then Lisp.eval(args[0]) < Lisp.eval(args[1])
      when :> then Lisp.eval(args[0]) > Lisp.eval(args[1])
      when :<= then Lisp.eval(args[0]) <= Lisp.eval(args[1])
      when :>= then Lisp.eval(args[0]) >= Lisp.eval(args[1])
      when :== then Lisp.eval(args[0]) == Lisp.eval(args[1])
      when :and then Lisp.eval(args[0]) && Lisp.eval(args[1])
      when :or then Lisp.eval(args[0]) || Lisp.eval(args[1])
      when :not then !Lisp.eval(args[0])
      when :if then Lisp.eval(args[0]) ? Lisp.eval(args[1]) : Lisp.eval(args[2])
      else raise ArgumentError, "unknown operator #{op.inspect}"
      end
    else
      raise ArgumentError, "unknown expression #{expr.inspect}"
    end
  end
end
