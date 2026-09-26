# Issue #1415 — the file that makes the classes `relative_constant_reader.rb` reopens and subclasses. Each constant
# write spells its path relative to the module it is written in, which the project's census of written constant
# names keeps as spelled (`Q::Qux` for `P::Q::Qux`).
require "csv"

module P
  module Q
  end
  Q::Qux = Class.new(CSV)
end

module R
  module Inner
  end
  Inner::IO = Class.new(CSV)
end
