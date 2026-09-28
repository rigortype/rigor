# frozen_string_literal: true

# https://github.com/rigortype/rigor/issues/1550 — a named module_function copies the def in effect at the call,
# so Fmt.label is the def on the first line of the body and returns "one". The later def redefines only the
# instance method. Rigor's singleton def-node table takes the later def.

module Fmt
  def label = "one"
  module_function :label
  def label = 2
end
