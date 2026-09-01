# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 4.0.0", "< 4.1"

gemspec

# Source override only — the version constraint stays on the gemspec's development dependency.
#
# The sharded `Tests` matrix in .github/workflows/ci.yml needs `binpacker run --shard K/N` and
# `binpacker shards-check`, which are on binpacker's master but not in any released gem: 0.4.0 predates
# them. Pinned to an explicit revision rather than a branch so a push to binpacker cannot silently change
# what Rigor's CI runs.
#
# Replace this whole entry with nothing — the gemspec dependency then resolves from rubygems again — as
# soon as a binpacker release carries sharding.
gem "binpacker", git: "https://github.com/rigortype/binpacker", ref: "6019ce9acc2882faa7496a24f54a25dbb8549f38"
