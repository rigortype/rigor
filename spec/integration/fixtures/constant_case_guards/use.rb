# Issue #1963 — guards for a constant `when` test or `===` receiver on a nilable subject. A clause matching an alias
# of a class from another file (`App::Error = Lib::Failure`), or a value constant (`LIMIT = 3`, `NAME = "x"`,
# another file's `Cfg::LIMIT`), runs only for a non-nil subject, and the read in it stays quiet. Under Ruby 4.0.5,
# with the flag true, `alias_when` and `alias_receiver` return "m", `limit_when`, `limit_receiver` and
# `cross_file_limit` return 4, and `name_when` returns "X".
LIMIT = 3
NAME = "x"

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

def limit_when(flag)
  x = flag ? 3 : nil
  case x
  when LIMIT then x.succ
  end
end

def name_when(flag)
  x = flag ? "x" : nil
  case x
  when NAME then x.upcase
  end
end

def limit_receiver(flag)
  x = flag ? 3 : nil
  x.succ if LIMIT === x
end

def cross_file_limit(flag)
  x = flag ? 3 : nil
  case x
  when Cfg::LIMIT then x.succ
  end
end
