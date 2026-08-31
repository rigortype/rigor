module ReopenM
  def self.reg(x)
    42
  end

  RSAME = reg(1)
end
RZC = ReopenM.reg(1).nosuch_reopenctl_xyz
