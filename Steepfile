# frozen_string_literal: true

D = Steep::Diagnostic

target :lib do
  signature "sig"

  check "lib"

  # Steep 2.0.0 crashes with a RuntimeError in type_hash when processing
  # generator.rb (a Hash literal whose value types it cannot resolve).
  # Tracked upstream; re-enable once a Steep patch ships.
  ignore "lib/rigor/sig_gen/generator.rb"

  library "pathname"
  library "yaml"
  library "json"
  library "optparse"
  library "logger"

  configure_code_diagnostics(D::Ruby.lenient)
end
