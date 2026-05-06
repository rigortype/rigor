# frozen_string_literal: true

# Tiny runtime — the plugin's value is the static check it
# performs at lint time. The runtime side is just enough to
# make demo.rb runnable.

PATTERNS = {
  email: /\A[^\s@]+@[^\s@]+\z/,
  uuid: /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
}.freeze

def validate(name, value)
  pattern = PATTERNS.fetch(name) { raise ArgumentError, "no pattern :#{name}" }
  raise "#{value.inspect} does not match :#{name}" unless pattern.match?(value)

  value
end
