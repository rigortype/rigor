# frozen_string_literal: true

require_relative "lib/runtime"

# Run with the plugin from inside this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# rigor-statesman performs a two-pass analysis on each file:
#   pass 1 — collect every `state :name` declaration inside
#            `state_machine do ... end` blocks.
#   pass 2 — validate every `transition_to(:sym)` call site
#            against the collected state set.

class Order
  state_machine do
    state :draft, initial: true
    state :submitted
    state :approved
    state :rejected

    event :submit do
      # transitions from: :draft, to: :submitted (runtime no-op)
    end
  end
end

order = Order.new

# Recognised transitions — known states.
order.transition_to(:submitted)
order.transition_to(:approved)
order.transition_to(:rejected)
order.transition_to(:draft)

# Non-Symbol arguments stay silent (the plugin can't statically
# know which state value the variable resolves to).
target = :submitted
order.transition_to(target)
