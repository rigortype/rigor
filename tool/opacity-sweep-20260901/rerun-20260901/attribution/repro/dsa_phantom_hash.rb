# Minimal repro of the phantom-Hash carrier (PR #559), Searching.rb:277-290 shape.
def remove_duplicates(array, size)
  j = 0
  i = 1
  while i < size
    array[j] = array[i]
    i += 1
  end
  array                      # BASE: Hash[Integer, Dynamic[top]] / NOW: Dynamic[top]
end

def control_seeded
  h = {}
  h[1] = 9
  h                          # a {}-seeded local must STILL join its stored pairs
end
