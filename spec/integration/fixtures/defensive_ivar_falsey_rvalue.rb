require "rigor/testing"
include Rigor::Testing

# Defensive ivar-init with a falsey-Constant rvalue
# (ROADMAP § Future cycles — "Defensive ivar-init with nil /
# false rvalue"). Without the class-ivar pre-pass skip:
#
#   `@x = nil unless @x` records `union(Constant[nil],
#   Constant[nil]) = Constant[nil]` into the accumulator, so
#   when the predicate `unless @x` evaluates it reads
#   `Constant[nil]` (a single Constant) and the
#   `flow.always-truthy-condition` rule fires on the
#   no-op-but-documented-default idiom.
#
# The skip drops this write's accumulator contribution
# (matching the `||=` no-seed behaviour). Other writes to
# the same ivar still contribute, but the falsey-default
# carries no useful precision the predicate hasn't already
# given us. Worked site: tdiary-core HEAD `ee40c2b`
# `lib/tdiary/configuration.rb:157`
# (`@x_frame_options = nil unless @x_frame_options`).

class Config
  def configure
    @x_frame_options ||= nil
    @show_nyear ||= false
    @header ||= ""
    @hide_comment_form = false unless defined?(@hide_comment_form)
  end
end
