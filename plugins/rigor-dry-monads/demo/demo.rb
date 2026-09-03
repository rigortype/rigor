# frozen_string_literal: true

def demo
  res = Success("hello")
  puts res.value!.upcase

  m = Some(42)
  puts m.value! + 1
end
