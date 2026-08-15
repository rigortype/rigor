# frozen_string_literal: true

require_relative "scan"

module Rigor
  module Analysis
    module Reachability
      # ADR-102 — the cross-file half: resolves every as-written reference to a declaration, then marks from the
      # root set. Pure data; no engine coupling, so `rigor check`'s diagnostic stream is untouched by
      # construction rather than by a gate (WD1).
      #
      # Resolution mirrors `Reflection.resolve_constant_type`'s candidate order — lexical nesting innermost
      # first, then the ancestors of the innermost cresting scope, then the bare name — because a reference
      # index that resolved names differently from the engine would report on a graph the analyzer does not
      # believe in. The two walks are separate implementations (this one is name-level and needs no types), so
      # `spec/rigor/analysis/reachability/graph_spec.rb` pins them to the same answers on shared fixtures.
      class Graph
        Candidate = Data.define(:fqn, :path, :line)

        # `test_only` is its own list, not a flag on `candidates`: a candidate is by definition unreachable, so
        # a flag there could never be true. "Reachable, but only from test code" is a SEPARATE and more
        # actionable answer — dead production code with a live test — which is exactly what ADR-102 WD8 requires
        # be reported as its own category rather than folded into a bucket boundary.
        Report = Data.define(:declared, :reachable, :candidates, :test_only, :namespaces, :roots, :edges)

        # @param declarations [Array<Scan::Declaration>]
        # @param references [Array<Scan::Reference>]
        # @param root_fqns [Enumerable<String>] declarations that are entry points regardless of who references
        #   them (config-declared globs in this slice; plugin-supplied roots are #349).
        # @param foreign [#call] predicate answering "is this FQN owned by something outside the project?" —
        #   a reopened gem or stdlib class must never be a candidate (WD6). Defaults to "nothing is foreign".
        def initialize(declarations:, references:, root_fqns: [], foreign: ->(_fqn) { false })
          @declarations = declarations
          @references = references
          @root_fqns = root_fqns.to_set
          @foreign = foreign
          @by_fqn = declarations.group_by(&:fqn)
          @owned = @by_fqn.keys.reject { |fqn| @foreign.call(fqn) }.to_set
          @ancestors = {}
        end

        def report
          edges = resolved_edges
          production = walk(edges, seeds: production_seeds, roles: %i[production task config])
          reachable = walk(edges, seeds: production_seeds | test_seeds, roles: %i[production task config test])
          unreached = @owned - reachable
          namespaces = namespace_only(unreached, reachable)
          Report.new(declared: @owned.size, reachable: reachable.size,
                     candidates: rows(unreached - namespaces), test_only: rows(reachable - production),
                     namespaces: namespaces.size, roots: production_seeds.size, edges: edges.size)
        end

        private

        # `module A; end` wrapping a live `A::B` is not dead code, but nothing ever references `A` by itself:
        # a reference to `A::B::Leaf` records the leaf only, never the intermediate segments. Reporting these
        # buried the real rows — 12 of 18 candidates on Rigor's own `lib`, and 22 of 140 in the #345 probe,
        # were pure namespaces.
        #
        # The test is deliberately "some REACHABLE declaration lives under it", not "some declaration lives
        # under it": a namespace whose entire contents are dead is itself a genuine finding, and its children
        # appear alongside it rather than being explained away.
        def namespace_only(unreached, reachable)
          unreached.select do |fqn|
            prefix = "#{fqn}::"
            reachable.any? { |other| other.start_with?(prefix) }
          end.to_set
        end

        # Seeds that make a declaration live in PRODUCTION: named entry points, plus anything referenced at
        # file level by a non-test file (file-level code runs on load, so its target is live).
        def production_seeds
          @production_seeds ||= (@root_fqns & @owned) | seeds_from { |ref| ref.from.nil? && ref.role != :test }
        end

        # Seeds that make a declaration live only through TEST code. Kept separate from production seeds
        # rather than folded in: a spec's file-level `Foo.new` would otherwise promote `Foo` to a root and
        # erase the very distinction WD8 exists to report.
        def test_seeds
          @test_seeds ||= seeds_from { |ref| ref.from.nil? && ref.role == :test }
        end

        def seeds_from
          set = Set.new
          @references.each do |ref|
            next unless yield(ref)

            target = resolve(ref.as_written, ref.nesting)
            set << target if target && @owned.include?(target)
          end
          set
        end

        # `[from_fqn_or_nil, to_fqn, role]` for every reference that resolves to an owned declaration.
        def resolved_edges
          @resolved_edges ||= @references.filter_map do |ref|
            target = resolve(ref.as_written, ref.nesting)
            next unless target && @owned.include?(target)
            next if ref.from == target # a declaration referencing itself is not evidence of use

            [ref.from, target, ref.role]
          end
        end

        # Mark-and-sweep, not reference counting: an edge only propagates if its SOURCE is itself reachable, so
        # a cluster of mutually-referencing dead classes stays dead (ADR-102 WD2).
        #
        # Run twice with different edge roles admitted (WD8). The production pass admits everything except
        # test-sourced edges; the full pass admits all of them. The difference is exactly "reachable, but only
        # from test code" — dead production code with a live test, which is a finding rather than a bucket edge.
        def walk(edges, seeds:, roles:)
          admitted = roles.to_set
          out = Hash.new { |h, k| h[k] = [] }
          edges.each { |from, to, role| out[from] << to if admitted.include?(role) }

          seen = seeds.dup
          queue = seeds.to_a
          until queue.empty?
            out[queue.shift].each do |target|
              next if seen.include?(target)

              seen << target
              queue << target
            end
          end
          seen
        end

        def rows(fqns)
          fqns.sort.map do |fqn|
            site = @by_fqn.fetch(fqn).first
            Candidate.new(fqn: fqn, path: site.path, line: site.line)
          end.freeze
        end

        # Ruby's constant lookup at name granularity: `Module.nesting` innermost first, then the ancestors of
        # the innermost cresting scope (#354), then the bare name.
        def resolve(as_written, nesting)
          walker = nesting.dup
          until walker.empty?
            candidate = (walker + [as_written]).join("::")
            return candidate if @by_fqn.key?(candidate)

            walker.pop
          end

          unless nesting.empty?
            ancestor_scopes(nesting.join("::")).each do |ancestor|
              candidate = "#{ancestor}::#{as_written}"
              return candidate if @by_fqn.key?(candidate)
            end
          end

          return as_written if @by_fqn.key?(as_written)

          # `Scope::DiscoveryIndex::EMPTY` names a constant INSIDE a class, and reading it is a use of that
          # class — but the leaf is not itself a declaration, so the reference would resolve to nothing and
          # `Scope::DiscoveryIndex` would be reported as unused despite being read all over the engine (it was,
          # on the first run of this report against Rigor's own `lib`). Peel the trailing segment and retry:
          # a reference to a member is a reference to its owner.
          idx = as_written.rindex("::")
          idx ? resolve(as_written[0, idx], nesting) : nil
        end

        # Breadth-first over superclass + included modules, mixins first, terminating on a cycle. As-written
        # ancestor names resolve against the subclass's own nesting; a name naming no declaration is dropped.
        def ancestor_scopes(fqn)
          @ancestors[fqn] ||= begin
            seen = Set[fqn]
            queue = [fqn]
            out = []
            until queue.empty?
              current = queue.shift
              @by_fqn.fetch(current, []).each do |decl|
                (decl.includes + [decl.superclass]).compact.each do |raw|
                  resolved = resolve_ancestor(current, raw)
                  next if resolved.nil? || seen.include?(resolved)

                  seen << resolved
                  out << resolved
                  queue << resolved
                end
              end
            end
            out.freeze
          end
        end

        def resolve_ancestor(subclass_fqn, raw)
          segments = subclass_fqn.split("::")
          (segments.length - 1).downto(0) do |i|
            candidate = (segments[0, i] + [raw]).join("::")
            return candidate if @by_fqn.key?(candidate)
          end
          nil
        end
      end
    end
  end
end
