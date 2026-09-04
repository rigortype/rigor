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
        Report = Data.define(:declared, :reachable, :candidates, :undecidable, :test_only, :namespaces,
                             :roots, :edges)

        # A candidate demoted out of `candidates` because something can reach it by a mechanism this reading
        # cannot follow (ADR-102 WD4). Carries the reason so the reader can judge it rather than take the
        # bucket on trust.
        Undecidable = Data.define(:fqn, :path, :line, :reason)

        # @param declarations [Array<Scan::Declaration>]
        # @param references [Array<Scan::Reference>]
        # @param root_fqns [Enumerable<String>] declarations that are entry points regardless of who references
        #   them (config-declared globs in this slice; plugin-supplied roots are #349).
        # @param foreign [#call] predicate answering "is this FQN owned by something outside the project?" —
        #   a reopened gem or stdlib class must never be a candidate (WD6). Defaults to "nothing is foreign".
        # @param dynamic_uses [Array<Scan::DynamicUse>] sites where a constant is reached by name at runtime.
        #   A literal-argument site contributes a real reference; a dynamic one taints a namespace (WD4).
        def initialize(declarations:, references:, root_fqns: [], dynamic_uses: [], foreign: ->(_fqn) { false })
          @declarations = declarations
          @dynamic_uses = dynamic_uses
          @references = references + literal_dynamic_references(dynamic_uses)
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
          # The data-file demotion applies to BOTH buckets it can speak to, which is what the tier
          # contract says and what the implementation had narrowed (#370). See {#tainted}.
          test_only = reachable - production
          undecidable = tainted(unreached - namespaces).merge(tainted(test_only))
          build_report(edges: edges, reachable: reachable, unreached: unreached, namespaces: namespaces,
                       test_only: test_only, undecidable: undecidable)
        end

        private

        def build_report(edges:, reachable:, unreached:, namespaces:, test_only:, undecidable:)
          demoted = undecidable.keys.to_set
          Report.new(declared: @owned.size, reachable: reachable.size,
                     candidates: rows(unreached - namespaces - demoted),
                     undecidable: undecidable.map { |fqn, reason| undecidable_row(fqn, reason) }.freeze,
                     test_only: rows(test_only - demoted),
                     namespaces: namespaces.size, roots: production_seeds.size, edges: edges.size)
        end

        # A literal-argument `"Foo::Bar".constantize` names its constant exactly, so it is a REFERENCE, not an
        # unknown. Keeping this distinct from the taint below is what stops the tier being a blanket namespace
        # poison — Rigor knows the argument's shape, and a type-free indexer does not.
        def literal_dynamic_references(dynamic_uses)
          dynamic_uses.filter_map do |use|
            next if use.name.nil?

            Scan::Reference.new(as_written: use.name.sub(/\A::/, ""), nesting: [].freeze, from: nil,
                                role: :production, path: use.path, line: use.line,
                                rooted: use.name.start_with?("::"))
          end
        end

        # `{fqn => reason}` for every declaration in `fqns` a dynamic site could still be naming. A site with a
        # literal prefix taints that namespace and everything under it; a site with no prefix at all cannot be
        # bounded, so it taints nothing rather than everything — poisoning the whole project would empty the
        # report and teach the reader that the tier means nothing.
        #
        # Asked of the unreached AND of the test-only set (#370). The tier contract says a name appearing in a
        # data file "MUST demote to this tier"; the implementation had asked only about the unreached, so a
        # declaration a spec references AND `config/recurring.yml` names kept its data-file evidence discarded
        # and landed under "live test, dead production path". That heading is an assertion about production,
        # and a scheduler entry is evidence against it — the reported case runs every three minutes.
        #
        # Both buckets ask a different question of the same ambiguity ("is this dead?" against "is the
        # production path dead?"), and the answer for both is that this reading cannot settle it. The reason
        # string is what tells the two apart for a reader, so it names the evidence rather than the bucket.
        def tainted(fqns)
          sites = @dynamic_uses.select { |use| use.name.nil? && use.prefix }

          return {} if sites.empty?

          fqns.each_with_object({}) do |fqn, out|
            use = sites.find { |site| site.taints?(fqn) }
            out[fqn] = use.site.nil? ? use.reason : "#{use.reason} (#{use.site})" if use
          end
        end

        def undecidable_row(fqn, reason)
          site = @by_fqn.fetch(fqn).first
          Undecidable.new(fqn: fqn, path: site.path, line: site.line, reason: reason)
        end

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

            target = resolve(ref.as_written, ref.nesting, rooted: ref.rooted)
            set << target if target && @owned.include?(target)
          end
          set
        end

        # `[from_fqn_or_nil, to_fqn, role]` for every reference that resolves to an owned declaration.
        def resolved_edges
          @resolved_edges ||= @references.filter_map do |ref|
            target = resolve(ref.as_written, ref.nesting, rooted: ref.rooted)
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
        # the innermost cresting scope (#354), then the bare name. When `rooted: true`, lexical nesting and
        # ancestors are skipped, answering the top-level declaration directly (#625).
        def resolve(as_written, nesting, rooted: false)
          if rooted
            return as_written if @by_fqn.key?(as_written)

            idx = as_written.rindex("::")
            return idx ? resolve(as_written[0, idx], nesting, rooted: true) : nil
          end

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
