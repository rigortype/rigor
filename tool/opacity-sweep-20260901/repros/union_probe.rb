s = rand < 0.5 ? "abc" : nil
a = s.upcase
b = s&.upcase
t = rand < 0.5 ? "abc" : :sym
c = t.to_s
n = rand < 0.5 ? 1 : "x"
d = n.frozen?
