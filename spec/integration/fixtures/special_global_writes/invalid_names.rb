# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — a name literal whose bytes are not valid UTF-8, handed to a string `class_eval`, to `define_method`
# and to `send`. The census cannot read such a name, so it counts it as every name, and the writes whose setter asks
# the value for a method stay quiet, although Ruby raises for them here too. The file is still analysed: a setter that
# converts nothing reports, and so does an unrelated call. Ruby 4.0.5 raises `SyntaxError` for the eval and
# `EncodingError` for the other two, which each method rescues. A line marked FIRES-1367 quotes the error Ruby raises.
def patch_by_eval(klass)
  klass.class_eval("\xff def write(*) = 0 end")
rescue SyntaxError
  nil
end

def patch_by_define_method(klass)
  klass.define_method("\xff") { |*| 0 }
rescue EncodingError
  nil
end

def patch_by_send(klass)
  klass.send("\xff", :write)
rescue EncodingError
  nil
end

def stream = ($stdout = 1) # QUIET-1367
def program_name = ($0 = 1) # QUIET-1367
def separator = ($/ = 1) # FIRES-1367 global.write-type-mismatch — value of $/ must be String
def unrelated = 1.no_such_method # FIRES-1367 call.undefined-method — undefined method 'no_such_method' for an instance of Integer
# rubocop:enable Style/SpecialGlobalVars
