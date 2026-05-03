# frozen_string_literal: true

D = Steep::Diagnostic

target :lib do
  signature "sig"

  check "lib"

  library "pathname"
  library "yaml"
  library "json"
  library "optparse"
  library "logger"

  configure_code_diagnostics(D::Ruby.lenient)
end
