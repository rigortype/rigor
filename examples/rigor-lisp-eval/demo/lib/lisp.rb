# frozen_string_literal: true

# Tiny S-expression-style interpreter the plugin types statically. The runtime body is intentionally straightforward;
# the demo's value is what `rigor check` says about callers, not the runtime semantics here.
module Lisp
  module_function

  def eval(expr, env = {})
    case expr
    when Integer, Float, true, false
      expr
    when Symbol
      raise ArgumentError, "unbound variable #{expr.inspect}" unless env.key?(expr)

      env[expr]
    when Array
      raise ArgumentError, "empty form" if expr.empty?

      op, *args = expr
      case op
      when :+ then Lisp.eval(args[0], env) + Lisp.eval(args[1], env)
      when :- then Lisp.eval(args[0], env) - Lisp.eval(args[1], env)
      when :* then Lisp.eval(args[0], env) * Lisp.eval(args[1], env)
      when :/ then Lisp.eval(args[0], env) / Lisp.eval(args[1], env)
      when :< then Lisp.eval(args[0], env) < Lisp.eval(args[1], env)
      when :> then Lisp.eval(args[0], env) > Lisp.eval(args[1], env)
      when :<= then Lisp.eval(args[0], env) <= Lisp.eval(args[1], env)
      when :>= then Lisp.eval(args[0], env) >= Lisp.eval(args[1], env)
      when :== then Lisp.eval(args[0], env) == Lisp.eval(args[1], env)
      when :and then Lisp.eval(args[0], env) && Lisp.eval(args[1], env)
      when :or then Lisp.eval(args[0], env) || Lisp.eval(args[1], env)
      when :not then !Lisp.eval(args[0], env)
      when :if then Lisp.eval(args[0], env) ? Lisp.eval(args[1], env) : Lisp.eval(args[2], env)
      when :let
        bindings, body = args
        child_env = env.dup
        bind_runtime(bindings, child_env, env)
        Lisp.eval(body, child_env)
      else raise ArgumentError, "unknown operator #{op.inspect}"
      end
    else
      raise ArgumentError, "unknown expression #{expr.inspect}"
    end
  end

  def bind_runtime(bindings, child_env, eval_env)
    return unless bindings.is_a?(Array) && !bindings.empty?

    if bindings[0].is_a?(Symbol)
      child_env[bindings[0]] = Lisp.eval(bindings[1], eval_env)
    elsif bindings.size == 2 && bindings[0].is_a?(Array) && bindings[1].is_a?(Array) && !binding_pair?(bindings[1])
      extract_pattern_runtime(bindings[0], bindings[1], child_env, eval_env)
    else
      bindings.each do |elem|
        if elem[0].is_a?(Symbol)
          child_env[elem[0]] = Lisp.eval(elem[1], eval_env)
        elsif elem.size == 2 && elem[0].is_a?(Array)
          extract_pattern_runtime(elem[0], elem[1], child_env, eval_env)
        end
      end
    end
  end

  def extract_pattern_runtime(pattern, value, child_env, eval_env)
    if pattern.is_a?(Symbol)
      child_env[pattern] = value.is_a?(Array) ? value : Lisp.eval(value, eval_env)
      return
    end

    val_arr = value.is_a?(Array) ? value : Lisp.eval(value, eval_env)
    pattern.each_with_index do |p, idx|
      extract_pattern_runtime(p, val_arr[idx], child_env, eval_env)
    end
  end

  def binding_pair?(val)
    val.is_a?(Array) && val.size == 2 && (val[0].is_a?(Symbol) || val[0].is_a?(Array))
  end
end
