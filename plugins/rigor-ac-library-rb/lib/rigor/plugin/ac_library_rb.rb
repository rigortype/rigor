# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    # A pure RBS-bundle plugin for ac-library-rb, the Ruby port of the AtCoder Library. It emits no diagnostic and
    # declares no producer: the manifest's `signature_paths: ["sig"]` adds the bundled `AcLibraryRb` signatures to the
    # RBS environment.
    #
    # Inference cannot write these. The containers are generic over values the caller picks (a segment tree's monoid,
    # a priority queue's elements), and their methods read parameters no call site in the library constrains, so
    # `rigor sig-gen` over the gem's `lib_lock/` leaves 95 of its methods untyped. The signatures were written against
    # that output and the gem's documentation, and `rigor check` over `lib_lock/` holds the method bodies to them.
    class AcLibraryRb < Base
      manifest(
        id: "ac-library-rb",
        target_gems: ["ac-library-rb"],
        version: "0.1.0",
        description: "RBS bundle for ac-library-rb (AtCoder Library): Segtree, LazySegtree, DSU, ModInt, flows " \
                     "and the math and string algorithms.",
        signature_paths: ["sig"]
      )
    end
  end
end

Rigor::Plugin.register(Rigor::Plugin::AcLibraryRb)
