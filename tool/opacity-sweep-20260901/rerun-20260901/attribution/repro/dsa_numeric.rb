# Minimal repro of the DSA binarySearch shape (Searching/Searching.rb:25-37).
def bs(arr, size, value)
  low = 0
  high = size - 1
  mid = (low + high) / 2
  mid
end

def bs_loop(arr, size, value)
  low = 0
  high = size - 1
  while low <= high
    mid = (low + high) / 2
    low = mid + 1
  end
  low
end

def control(size)
  low = 0
  high = 7
  mid = (low + high) / 2
  mid
end
