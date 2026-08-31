class SpCheck
  def self.spl(*a)
    7
  end

  def self.pln(a)
    7
  end

  def self.kwr(**o)
    7
  end
end

PLX = SpCheck.pln(1).nosuch_plain_xyz
SPX = SpCheck.spl(1).nosuch_splat_xyz
KWX = SpCheck.kwr(a: 1).nosuch_kwr_xyz

RBC = ("a" == "b").nosuch_boolctl_xyz
RBX = (RUBY_PLATFORM == "java").nosuch_refined_xyz

module ExtM
  def extdef(a)
    9
  end
end

class ExtHost
  extend ExtM

  def self.own(a)
    9
  end
end

EOC = ExtHost.own(1).nosuch_ownctl_xyz
EOX = ExtHost.extdef(1).nosuch_ext_xyz

MyS = Struct.new(:a)
MSX = MyS.new(1).nosuch_struct_xyz

class KlassSelf
  class << self
    def me
      "s"
    end
  end
end

KS_SAME = KlassSelf.me.nosuch_ks_same_xyz

def nilable_probe(flag)
  s = flag ? "x" : nil
  a = s.length
  b = "x".length.nosuch_len_ctl_xyz
  c = s.length.nosuch_nilable_xyz
  [a, b, c]
end
