# frozen_string_literal: true

# ADR-129 — reads and writes a declared `Rigor::TypingState` slot on the calling thread, by name. A spec
# that pins a slot's storage shape names it: the slot constant is a `private_constant` of its owner, and the point of
# such a spec is that no production caller can observe the slot.
module TypingStateSlots
  def typing_slot(name)
    Rigor::TypingState.current[Rigor::TypingState.slot(name).index]
  end

  def set_typing_slot(name, value)
    Rigor::TypingState.current[Rigor::TypingState.slot(name).index] = value
  end
end

RSpec.configure { |config| config.include TypingStateSlots }
