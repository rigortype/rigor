def go(_)
  x = if rand < 0.5
    "hello"
  else
    nil
  end
  return if x.nil?
  x
end
