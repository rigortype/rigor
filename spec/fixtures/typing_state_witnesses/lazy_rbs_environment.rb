# ADR-129 G1' witness for :file_digest_run and :rbs_core_root. The constant-write census types `H = Helper` before the
# file is walked, and resolving `Helper` demands the set of known class names, which the loader fetches lazily from
# inside that `type_of`: the cache producer's descriptor digests the signature files through the run's digest tables,
# and a miss builds the environment under the core root. A harness runs this with a cache store, and with `core_root:`
# set for the second slot.
module Helper
  def self.shout(text) = text.upcase
end
H = Helper

class Probe
  def run = H.shout("a")
end
