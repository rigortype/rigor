# frozen_string_literal: true

require "ffi"

module CMath
  extend FFI::Library
  ffi_lib "m"

  attach_function :cos, [:double], :double
  attach_function :sin, [:double], :double
end

puts CMath.cos(0.0)
