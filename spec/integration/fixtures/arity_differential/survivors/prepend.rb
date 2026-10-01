# A prepended module's method is the one that runs.
module Loud
  def speak(word) = word
end

class Speaker
  prepend Loud
end

Speaker.new.speak
