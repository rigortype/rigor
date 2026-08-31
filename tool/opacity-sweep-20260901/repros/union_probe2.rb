s = rand < 0.5 ? "abc" : nil
a = s&.to_s
b = s&.inspect
c = s.to_s
