require "rigor/testing"
include Rigor::Testing

# Issue #1963 — a constant `cfg.rb` binds with a value names no class here, although its value reads `Dynamic[top]`
# across files: no `when` test narrows `v`, rather than narrowing it to a class called `Cfg::NAME`. `Cfg::TEXT`,
# which holds `String`, narrows nothing either. Under Ruby 4.0.5 `use(1)` returns 1 (from `CHECK`), `use(0)` returns
# "x" (from `NAME`), `use_text(0)` returns "x" and `Cfg.inner(0)` returns "x".
def use(n)
  v = n.zero? ? "x" : 1
  case v
  when Cfg::NAME then assert_type('"x" | 1', v)
  when Cfg::PATTERN then assert_type('"x" | 1', v)
  when Cfg::CHECK then assert_type('"x" | 1', v)
  when Cfg::RANGE then assert_type('"x" | 1', v)
  end
end

def use_text(n)
  v = n.zero? ? "x" : 1
  case v
  when Cfg::TEXT then assert_type('"x" | 1', v)
  end
end

module Cfg
  def self.inner(n)
    v = n.zero? ? "x" : 1
    case v
    when NAME then assert_type('"x" | 1', v)
    end
  end
end
