# Minimal repro: PR #537 wrong-precise -> honest-Dynamic trade (numo-narray shape).
# Array#* has two RBS arms: (int) -> Array[T] and (string) -> String.
class Repro
  def flip(n)          # n is Dynamic[top] (parameter_inference off, as the probe runs)
    idx = [true] * n   # BASE: String (wrong precise) / NOW: Dynamic[Array[true] | String]
    x = idx.dup        # BASE: String / NOW: Dynamic[top]  (second-order)
    x
  end

  def control_int
    idx = [true] * 3   # typed Integer arg: single winner, must STAY precise
    idx
  end

  def control_str
    idx = [true] * ", " # typed String arg: single winner, must STAY precise
    idx
  end

  def flip_num(a, b)
    c = a + b + 1      # numeric-arith variant of the same join
    c
  end
end
