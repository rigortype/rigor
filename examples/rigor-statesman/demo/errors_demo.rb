# frozen_string_literal: true

# Intentionally ill-typed file — demonstrates the diagnostics
# rigor-statesman emits for unknown state references. DO NOT
# run via `ruby errors_demo.rb` — the unknown states would
# raise at runtime. Run `rigor check` instead.

require_relative "lib/runtime"

# The plugin scopes states to the file. Repeat the
# state_machine declaration here so the validator has
# something to compare against — same shape a real Statesman
# user would write in their `app/models/order.rb`.
class Order
  state_machine do
    state :draft, initial: true
    state :submitted
    state :approved
    state :rejected
  end
end

order = Order.new

# Typo close to a declared state — did-you-mean fires.
order.transition_to(:approval)   # error: unknown state :approval (did you mean :approved?)
order.transition_to(:submited)   # error: unknown state :submited (did you mean :submitted?)

# Not close to anything — error without a hint.
order.transition_to(:purgatory)  # error: unknown state :purgatory
