# frozen_string_literal: true

# Issue #870 — emits the mutually recursive visitor whose analysis cost grows exponentially in the
# method count since PR #547 removed the per-signature bail-out. `visitor_6.rb` next to this file is
# this generator's size-6 output, checked in so the spec suite keeps exercising the shape; larger
# sizes are for measurement runs and are not committed.
#
#   ruby spec/fixtures/issue_870_mutual_recursion/generate.rb 14 3 > /tmp/visitor_14.rb
#
# ARGV[0] is the method count, ARGV[1] the per-method call fan-out (default 3).
size = Integer(ARGV.fetch(0))
fan = Integer(ARGV.fetch(1, 3))

out = +"class Visitor\n"
size.times do |index|
  out << "  def visit_#{index}(node, indent = 0, force: false)\n"
  out << "    return node if force\n"
  fan.times do |offset|
    callee = (index + offset + 1) % size
    out << "    a#{offset} = visit_#{callee}(node, indent + #{offset}, force: #{offset.even?})\n"
  end
  out << "    #{Array.new(fan) { |offset| "a#{offset}" }.join(' || ')}\n"
  out << "  end\n"
end
out << "end\n"

print out
