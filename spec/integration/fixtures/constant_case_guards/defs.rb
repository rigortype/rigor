# Issue #1963 — constants another file reads in `when` tests and `===` receivers (`use.rb`).
module Lib
  class Failure < StandardError; end
end

module App
  Error = Lib::Failure
end

module Cfg
  LIMIT = 3
end
