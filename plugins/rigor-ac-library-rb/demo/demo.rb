# frozen_string_literal: true

require "ac-library-rb/segtree"
require "ac-library-rb/dsu"
require "ac-library-rb/modint"
require "ac-library-rb/max_flow"

seg = AcLibraryRb::Segtree.new([5, 3, 8, 1], -Float::INFINITY) { |x, y| [x, y].max }
puts seg.prod(1, 3)
puts seg.max_right(0) { |v| v < 8 }

uf = AcLibraryRb::DSU.new(4)
uf.merge(0, 1)
puts uf.groups.map(&:size).inspect

AcLibraryRb::ModInt.set_mod(998_244_353)
puts (AcLibraryRb::ModInt.new(3) * 5).val

graph = AcLibraryRb::MaxFlow.new(3)
graph.add_edge(0, 1, 4)
graph.add_edge(1, 2, 3)
puts graph.flow(0, 2)
