CB1 = CrossErr.build(:a)
CB2 = CrossPlain.build(:a)
CB3 = CrossPlain.new
CB4 = CrossPlain.new.imeth(1)
CB5 = CrossPlain.new.selfret(1)
CROSS_NEW_BAD = CrossPlain.new.nosuch_recv_xyz
CROSS_SUM_BAD = CrossPlain.new.imeth(1).nosuch_on_int_xyz
KS_CROSS = KlassSelf.me.nosuch_ks_cross_xyz
