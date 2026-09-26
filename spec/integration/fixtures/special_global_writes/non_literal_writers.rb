# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — objects that gain `write` on their own singleton, which Ruby 4.0.5's stream setter accepts. None is a
# literal, so none is judged. They sit in a file of their own: a `write` defined anywhere in a program keeps every
# stream literal in it from being reported, which would silence setter_rejections.rb's firing lines.
def stdout_singleton_writer = ($stdout = Object.new.tap { def _1.write(*) = 0 }) # QUIET-1367

def stdout_string_buffer
  buf = +""
  def buf.write(text) = (self << text; text.size)
  $stdout = buf # QUIET-1367
end

def stdout_array_buffer
  out = []
  out.define_singleton_method(:write) { |*texts| concat(texts).size }
  $stdout = out # QUIET-1367
end
# rubocop:enable Style/SpecialGlobalVars
