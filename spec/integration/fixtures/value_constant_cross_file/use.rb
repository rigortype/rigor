# Issue #1963 — another file's constant whose value is not published reads `Dynamic[top]` here, and may alias a
# class (`App::Error = Lib::Failure`), so a `when` test or `===` receiver naming it keeps narrowing by its spelling, as
# before: the alias reads drop the subject's `nil`, as the class they alias does, and stay quiet. Under Ruby 4.0.5
# `alias_when(true)` and `alias_receiver(true)` return "m", `use(1)` returns 2 (from `CHECK`) and `use(0)` returns
# "X" (from `NAME`).
def alias_when(flag)
  err = flag ? Lib::Failure.new("m") : nil
  case err
  when App::Error then err.message
  end
end

def alias_receiver(flag)
  err = flag ? Lib::Failure.new("m") : nil
  err.message if App::Error === err
end

def use(n)
  v = n.zero? ? "x" : 1
  case v
  when Cfg::NAME then v.upcase
  when Cfg::PATTERN then v.upcase
  when Cfg::CHECK then v + 1
  when Cfg::RANGE then v + 1
  when Cfg::TEXT then v.upcase
  end
end
