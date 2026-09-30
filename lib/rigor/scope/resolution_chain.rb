# frozen_string_literal: true

module Rigor
  class Scope
    # ADR-24 (amended for #1567, #1568, #1570 and #1571) — Ruby's method resolution order for one project class or
    # module, built from the discovery tables. Internal: `Scope`'s readers, the check rules and `Reflection`
    # read it, and it is not part of the plugin surface `Scope` exposes. This is the ONE place that walks
    # `discovered_includes`,
    # `discovered_prepends`, `discovered_superclasses` and `discovered_extends` transitively to answer "which
    # definer does Ruby call": `Scope#user_def_through_ancestors` and its siblings, the override rules, the
    # constant ladder's ancestor rung and `call.wrong-arity`'s level walk all read it, and
    # `spec/rigor/scope/ancestry_walker_detection_spec.rb` fails on a new method that walks the tables itself.
    #
    # The walks it replaced were breadth-first, which is not Ruby's order: `class C < Base; include A` with `A`
    # including `M` reaches `Base` (depth 1) before `M` (depth 2), while `C.ancestors` is `[C, A, M, Base]`.
    # The chain instead replays CRuby's own insertion rule (`include_modules_at` in `class.c`) over the tables:
    #
    # - A class's chain is the class followed by its superclass's chain; a module has no superclass.
    # - Each `prepend`, in statement order, inserts the module's own chain directly before the class, skipping a
    #   module already in the class's prepend region (and ONLY there — `class C < B; prepend W` where `B`
    #   includes `W` gives `[W, C, B, W]`).
    # - Each `include`, in statement order (`include M, N` is `include N; include M`), inserts the module's own
    #   chain directly after the class, skipping a module already ANYWHERE in the chain — the superclass's
    #   included and prepended modules too (#1570: `class C < Base; include M` where `Base` includes `M` is a
    #   no-op). A skipped module found between the insertion point and the superclass moves the insertion point
    #   past it, which is how `include M; include Z` with `Z` including `M` gives `[C, Z, M]`.
    # - The singleton side is the class object's singleton, its `extend`s and `class << self; include`s
    #   inserted by the include rule (each module expanded to its instance chain), then the superclass's
    #   singleton chain.
    #
    # The insertion rule is Ruby's for the order the statements RAN in, and the tables hold only their final
    # state. The chain therefore replays every edge once, eagerly, and counts a FORK wherever Ruby's own order
    # could have gone another way. The single-route argument (`class.c`): Ruby skips an insertion only when the
    # module is already present, and that takes a second route to it through the tables. So where the replay
    # inserts every entry exactly once and no owner on the chain is unsettled (below), Ruby's first-occurrence
    # ancestor order equals the replay's under every interleaving of the statements. A fork is a place where a
    # module reached a chain by a second route: an `include` skipped because the chain carries the module, a
    # prepend skipped or an entry of a prepended module's own chain already carried by the class. The ONE
    # decision every first-definer reader makes is {#settle}: with no fork the chain stands; with exactly one
    # include-side fork, at or after the class, on the last entry of the sub-chain being inserted, Ruby has
    # exactly two worlds (the skip made, or the insertion made — `class Base; include M; end` after `class C <
    # Base; include M` keeps both copies, `[C, M, Base, M]`), and the chain stands only where that retro world
    # gives the reader the same answer; with any other fork or two or more the worlds are more than two and
    # the chain never stands. Where it does not stand, a reader answers what the walk this chain replaced
    # answered ({MasterOrder}): the tables cannot say which world ran, and a disagreement is no reason to
    # answer anything new. That leaves #1570's redundant `include` with the answer master gave, since the two
    # worlds disagree there; ADR-119's arity decision point is where it gets fixed.
    #
    # Two things the tables do not record, so the chain cannot reproduce them:
    #
    # - The interleaving of a body's `include` and `prepend` statements, and whether a class both includes and
    #   prepends one module (`include M; prepend M` is `[M, C, M]` in Ruby; the tables record it as a plain
    #   `prepend M`). Each kind keeps its statement order and the chain processes a body's prepends before its
    #   includes. Only the trailing duplicate is ever missing, so a first-occurrence reader is unaffected
    #   until a later include propagates into the prepended module (`module M0; prepend M1; end`, `class C;
    #   include M0; end`, then `module M0; include M1; end` and `module M1; include M3; end` is `[C, M1, M0,
    #   M1, M3]` in Ruby and `[C, M1, M3, M0]` here), which is why an entry of a prepended module's own chain
    #   that the class already carries is a fork. The same holds through a module's own includes (`class C2;
    #   include A; prepend M` with `A` including `M` is `[M, C2, A, M]` in Ruby and `[M, C2, A]` here).
    #   CRuby also propagates a later prepend into the includers of a prepended module and leaves a trailing
    #   duplicate (`module M0; prepend M3; end; class Base; prepend M0; end; module M0; prepend M4; end` is
    #   `[M4, M3, M0, M4, Base]`); the first-occurrence order is the chain's, and the duplicate is not modelled.
    # - `class << self; prepend P`, which the extends table records (and the extends fold copies) as an
    #   `extend`: the chain places `P` after the singleton, where Ruby places it before.
    #
    # An ancestor the project does not declare (`Enumerable`, `< ActiveRecord::Base`) is an EXTERNAL entry at
    # its Ruby position, carrying the name as written and the names that spelling can denote; its own RBS
    # ancestry is not expanded. `Object`, `Kernel` and `BasicObject` are implicit after a chain whose last
    # superclass the project declares. Which as-written names count as project classes is the reader's
    # FLAVOR, because the three consumers asked three different questions before this chain existed and a bug
    # fix does not unify them:
    #
    # - `:methods` — `Scope#known_user_class?`, the method walks' predicate since #723;
    # - `:constants` — a key of `discovered_superclasses`, `discovered_includes` or `discovered_classes`, the
    #   constant ladder's (#354), which also admits a module that holds only constants;
    # - `:arity` — `Scope#known_user_class?` or a `discovered_parameter_envelopes` key, `call.wrong-arity`'s
    #   (#992), which also expands a name a compact-header rename left ambiguous to BOTH classes it can name
    #   (#986): their mutual order is load order, and the arity rule's per-level agreement absorbs it.
    #
    # Building a chain records nothing (ADR-46): it reads the tables raw and is memoised per discovery index.
    # A READ records, through {#search} and {#record}.
    class ResolutionChain
      # One ancestor on a chain. A project entry names a class or module (`name`) on `side` `:instance` (its
      # instance methods) or `:singleton` (the class object's singleton). An external entry has no `name`: it
      # keeps the spelling (`raw`) and its candidate names (`candidates`, most qualified first, empty for an
      # ambiguous spelling), and `superclass_edge` says it was reached through a superclass edge.
      Entry = Data.define(:name, :side, :raw, :candidates, :superclass_edge) do
        def external? = name.nil?
      end

      # How many project entries a chain may hold before it is cut (ADR-41 WD4). The breadth-first walks
      # counted visited project nodes against the same number.
      LIMIT = 100

      attr_reader :root, :side, :entries, :level_starts, :level_classes

      # rubocop:disable-next Metrics/ParameterLists
      def initialize(root:, side:, entries:, level_starts:, level_classes:, levels_end:, truncated:, forks: 0,
                     unsettled: false, retro: nil)
        @root = root
        @side = side
        @entries = entries
        @level_starts = level_starts
        @level_classes = level_classes
        @levels_end = levels_end
        @truncated = truncated
        @forks = forks
        @unsettled = unsettled
        @retro = retro
        freeze
      end

      # True when the chain was cut at {LIMIT} project entries: a reader that found nothing on it cannot tell
      # "no definer" from "a definer past the cut", which is budget uncertainty, not absence.
      def truncated? = @truncated

      # How many forks the replay met while this chain was built, counted across every module sub-chain it drew
      # on (a memoised sub-chain hands its own count up): each entry that reached the chain by a second route.
      # An over-count only ever sends a reader to master's answer.
      attr_reader :forks
      alias skip_count forks

      # True when a class on the chain has mixin edges whose order the tables cannot vouch for
      # (`DiscoveryIndex#unpositioned_mixins`, or a class declared in several files with several edges).
      def unsettled? = @unsettled

      # The ONE decision every first-definer reader makes: does `answer`, read off this chain, stand, or does
      # the reader answer what the walk this chain replaced answered ({MasterOrder})? Returns `:chain` or
      # `:master`.
      #
      # - Unsettled (a class on the chain has a mixin edge whose order is not a fact, or is declared in several
      #   files with several edges): master's answer, whatever the fork count, and the block is not called.
      # - No fork: every entry was inserted once by a single route, so Ruby's first-occurrence order is the
      #   chain's under every interleaving, and the chain stands.
      # - One fork that is an include-side skip at or after the class on the last entry of the sub-chain: two
      #   worlds (the skip made, the insertion made). The chain stands when the retro world gives the same
      #   answer, which the block computes from the chain it is handed; where they differ, or the retro world
      #   was too large to build, master's answer stands.
      # - Any other fork, or two or more: more than two worlds, so no answer read off two of them is
      #   trustworthy. Master's answer stands, and the block is not called.
      #
      # #1570 is a one-fork disagreement, so its readers answer master's until ADR-119 gives the arity rule's
      # decision point a way to decline.
      def settle(scope, answer)
        # The verdict depends on EVERY node of the chain (a fork, an unpositioned edge, a second declaring file),
        # and `:master` changes the answer, so the whole chain's class edges are dependencies whichever way it
        # goes; `search` files only the entries ahead of an answer.
        record(scope)
        return :master if @unsettled

        case @forks
        when 0 then :chain
        when 1 then !@retro.nil? && answer == yield(@retro) ? :chain : :master
        else :master
        end
      end

      # Walks the entries in Ruby's order from `start` up to (not including) `stop`, and returns the first
      # truthy value the block gives for an entry, or nil. `side:` yields only the entries on that side.
      #
      # The ADR-46 contract is the one the breadth-first walks had, in Ruby's order and in the order they filed
      # it: the answer depends on every project entry AHEAD of it — each one's ancestry edges decided where the
      # next one sits — so each records a class edge as the search passes it, and so does the root, first, when
      # it does not head the part searched (its prepends, or its own edges when the search starts past it,
      # placed the rest). The entry that answers records none of its own: its method edge is the caller's
      # `Scope#user_def_for`. A read that finds nothing has passed every entry.
      def search(scope, start = 0, stop = nil, side: nil)
        recording = Analysis::DependencyRecorder.active?
        stop ||= @entries.size
        record_head(scope, start, side) if recording
        index = start
        while index < stop
          entry = @entries[index]
          answer = side.nil? || entry.side == side ? yield(entry) : nil
          return answer if answer

          ResolutionChain.record_entry(scope, entry, side) if recording
          index += 1
        end
        nil
      end

      # Records the ADR-46 class edge of the root and of every project entry ahead of `stop` (on `side`, when
      # given; every entry when `stop` is nil) — the dependency of a read that consulted those positions.
      def record(scope, stop = nil, side: nil)
        return unless Analysis::DependencyRecorder.active?

        ResolutionChain.record_class(scope, @root)
        (stop || @entries.size).times do |index|
          entry = @entries[index]
          ResolutionChain.record_entry(scope, entry, side)
          record_appeared(entry, side)
        end
      end

      # The negative class edge of an entry the whole chain read (a verdict of {#settle}): a NEW file declaring
      # or reopening the class changes the edges the verdict counted (a second declaring file, another mixin),
      # and the class edges above name only the files that declare it now. Keyed on the unqualified name, as the
      # appeared-class widening reads it.
      def record_appeared(entry, side)
        return if side && entry.side != side

        Analysis::DependencyRecorder.read_missing(:class, (entry.name || entry.raw).to_s.split("::").last)
      end
      private :record_appeared

      def record_head(scope, start, side)
        ResolutionChain.record_class(scope, @root) unless start.zero? && @entries.first&.name == @root
        start.times { |index| ResolutionChain.record_entry(scope, @entries[index], side) }
      end
      private :record_head

      # `Scope#record_class_dependency`'s edge, filed from outside `Scope`: every file that declares `name`.
      def self.record_class(scope, name)
        sites = scope.discovery.discovered_class_sources[name.to_s]
        sites&.each { |site| Analysis::DependencyRecorder.read_site(site) }
      end

      def self.record_entry(scope, entry, side)
        return if side && entry.side != side

        if entry.external?
          # An ancestor the project does not treat as a class may still be DECLARED (an empty module in another
          # file), and a later edit there turns it into a project entry that moves the answer: file the sites
          # of every name its spelling can denote.
          entry.candidates.each { |candidate| record_class(scope, candidate) }
        else
          record_class(scope, entry.name)
        end
      end

      # The position of `name`'s own entry on this chain's side, or nil. A module can appear twice (a prepend
      # of a module the superclass includes); a class or the root cannot.
      def index_of(name, side = @side)
        @entries.index { |entry| entry.name == name && entry.side == side }
      end

      # A LEVEL is one superclass step: the class (or its singleton) with the modules inserted around it,
      # before the next superclass's entries begin. `level_classes[k]` is that class, or nil for a level that
      # is an external superclass. Only COMPLETE levels are counted — a level the {LIMIT} cut in half is not.
      def level_count = @level_starts.size

      def level_entries(index)
        finish = @level_starts[index + 1] || @levels_end
        @entries[@level_starts[index]...finish]
      end

      # Each complete level up to the first superclass the project does not declare, as `[class_name,
      # modules, externals]`: the level's class, the project modules around it (each once), and the candidate
      # lists of the ancestors in it the project does not declare — the shape `call.wrong-arity` reads.
      def levels
        out = []
        level_count.times do |index|
          class_name = @level_classes[index]
          break if class_name.nil?

          externals, entries = level_entries(index).partition(&:external?)
          modules = entries.filter_map { |entry| entry.name unless entry.name == class_name && entry.side == @side }
          out << [class_name, modules.uniq, externals.map(&:candidates)]
        end
        out
      end

      MEMO_KEY = :__rigor_resolution_chain__
      private_constant :MEMO_KEY

      FLAVORS = %i[methods constants arity].freeze

      # The chain for `class_name` on `side` under `flavor`. Memoised in ONE thread-local slot keyed on the
      # discovery index's identity — the same shape as `ExpressionTyper#class_graph_buckets`: the chain is a
      # pure function of that frozen index, and a store keyed on it would pin every file's index for the run.
      def self.for(scope, class_name, side, flavor)
        raise ArgumentError, "unknown resolution-chain flavor #{flavor.inspect}" unless FLAVORS.include?(flavor)

        bucket = flavor_bucket(scope.discovery, flavor)
        chains = bucket[side]
        chains[class_name] || (chains[class_name] = Builder.new(scope, flavor, bucket).chain(class_name, side))
      end

      def self.flavor_bucket(discovery, flavor)
        slot = Thread.current[MEMO_KEY]
        unless slot && slot[0].equal?(discovery)
          slot = [discovery, {}]
          Thread.current[MEMO_KEY] = slot
        end
        slot[1][flavor] ||= { instance: {}, singleton: {}, names: {}, interned: {}, externals: {}, master: {} }
      end

      # Which project class an as-written ancestor name denotes, under one flavor — shared by the chain and
      # by {MasterOrder}, and memoised per owner and name in the flavor's bucket.
      class Resolver
        def initialize(scope, flavor, bucket)
          @scope = scope
          @flavor = flavor
          @discovery = scope.discovery
          @names = bucket[:names]
        end

        # The project class `raw` denotes from `owner`'s declaration header, an Array of the classes an
        # ambiguous spelling names (`:arity` only), or nil.
        def resolve(owner, raw)
          by_owner = (@names[owner] ||= {})
          return by_owner[raw] if by_owner.key?(raw)

          by_owner[raw] = compute(owner, raw)
        end

        # {#resolve}, with an ambiguous spelling read as unresolved.
        def resolve_one(owner, raw)
          resolved = raw.nil? ? nil : resolve(owner, raw)
          resolved.is_a?(String) ? resolved : nil
        end

        def candidates(owner, raw) = @scope.ancestor_name_candidates(owner, raw)

        private

        def compute(owner, raw)
          found = candidates(owner, raw).find { |candidate| project?(candidate) }
          return found if found || @flavor != :arity

          alternatives = @scope.ambiguous_ancestor_resolutions(owner, raw)
          alternatives.empty? ? nil : alternatives
        end

        def project?(name)
          case @flavor
          when :constants
            @discovery.discovered_superclasses.key?(name) || @discovery.discovered_includes.key?(name) ||
              @discovery.discovered_classes.key?(name)
          when :arity
            @scope.known_user_class?(name) || @discovery.discovered_parameter_envelopes.key?(name)
          else
            @scope.known_user_class?(name)
          end
        end
      end
      private_constant :Resolver

      private_class_method :flavor_bucket

      # The orders the walks this chain replaced searched in, kept for the one case the chain cannot settle
      # alone: where its two worlds put different definers first, a reader answers what master answered
      # (ADR-24 § "Amendment 2026-09-28"), so no reader turns a disagreement into a new answer or a new
      # silence. Each order is the replaced walk's, over the same tables and the same name resolution, and is
      # memoised per root in the flavor's bucket. They are read so rarely — no chain on Rigor's own `lib`
      # needs one, and on Mastodon no read did — that their dependency edges are simply every node listed.
      module MasterOrder
        module_function

        # `Scope#user_def_through_ancestors`'s breadth-first search, prepend wedge and all: at each class,
        # its prepends' sub-chains, then the class, then its includes and superclass are queued.
        def definer_sequence(scope, root)
          ResolutionChain.master_memo(scope, :methods, [:definers, root]) do |resolver|
            out = []
            queue = [root]
            seen = {}
            until queue.empty? || seen.size > LIMIT
              current = queue.shift
              next if current.nil? || seen[current]

              seen[current] = true
              wedge(scope, resolver, current, {}).each do |name|
                next if seen[name]

                seen[name] = true
                out << name
              end
              out << current
              direct_edges(scope, resolver, current).each { |name| queue.push(name) }
            end
            out.freeze
          end
        end

        # The override rules' and the constant ladder's breadth-first order: every project ancestor after
        # `root`, nearer first, includes and prepends ahead of the superclass at each class.
        def breadth_first(scope, root, flavor)
          ResolutionChain.master_memo(scope, flavor, [:breadth_first, root]) do |resolver|
            out = []
            queue = direct_edges(scope, resolver, root)
            seen = { root => true }
            until queue.empty? || out.size > LIMIT
              current = queue.shift
              next if seen[current]

              seen[current] = true
              out << current
              queue.concat(direct_edges(scope, resolver, current))
            end
            out.freeze
          end
        end

        # `Scope#external_ancestor_name_candidates`'s depth-first walk: the candidate lists of the ancestors
        # the project does not declare, a resolved ancestor's own edges before the next sibling's.
        def external_groups(scope, root, mixins)
          ResolutionChain.master_memo(scope, :methods, [:externals, root, mixins]) do |resolver|
            groups = []
            collect_externals(scope, resolver, root, mixins, groups, {})
            groups.freeze
          end
        end

        # `call.wrong-arity`'s level walk: each class up the superclass chain with every module its own
        # mixins (`extend`s on the singleton side) reach, transitively, and the mixins that resolve to none.
        # Returns `[levels, whole]`, a level being `[class_name, modules, externals]`.
        def arity_levels(scope, root, side)
          ResolutionChain.master_memo(scope, :arity, [:levels, root, side]) do |resolver|
            levels = []
            current = root
            seen = {}
            whole = true
            while current && !seen[current]
              if seen.size >= LIMIT
                whole = false
                break
              end
              seen[current] = true
              levels << arity_level(scope, resolver, current, side)
              current = resolver.resolve_one(current, scope.discovery.discovered_superclasses[current])
            end
            [levels.freeze, whole].freeze
          end
        end

        def direct_edges(scope, resolver, name)
          discovery = scope.discovery
          raws = (discovery.discovered_includes[name] || EMPTY_NAMES) + [discovery.discovered_superclasses[name]]
          raws.filter_map { |raw| resolver.resolve_one(name, raw) }
        end

        def wedge(scope, resolver, name, seen)
          (scope.discovery.discovered_prepends[name] || EMPTY_NAMES).each_with_object([]) do |raw, out|
            resolved = resolver.resolve_one(name, raw)
            next if resolved.nil? || seen[resolved]

            seen[resolved] = true
            out.concat(subchain(scope, resolver, resolved, seen))
          end
        end

        def subchain(scope, resolver, name, seen)
          out = wedge(scope, resolver, name, seen)
          out << name
          direct_edges(scope, resolver, name).each do |resolved|
            next if seen[resolved]

            seen[resolved] = true
            out.concat(subchain(scope, resolver, resolved, seen))
          end
          out
        end

        def collect_externals(scope, resolver, current, mixins, groups, seen)
          return if seen[current] || seen.size > LIMIT

          seen[current] = true
          discovery = scope.discovery
          raws = mixins ? (discovery.discovered_includes[current] || EMPTY_NAMES).dup : []
          raws << discovery.discovered_superclasses[current]
          raws.compact.each do |raw|
            resolved = resolver.resolve_one(current, raw)
            next groups << resolver.candidates(current, raw) if resolved.nil?

            collect_externals(scope, resolver, resolved, mixins, groups, seen)
          end
        end

        def arity_level(scope, resolver, class_name, side)
          discovery = scope.discovery
          table = side == :singleton ? discovery.discovered_extends : discovery.discovered_includes
          own = table[class_name]
          modules = []
          externals = []
          collect_mixins(scope, resolver, class_name, own || EMPTY_NAMES, [modules, externals], {})
          [class_name, modules.freeze, externals.freeze].freeze
        end

        def collect_mixins(scope, resolver, owner, raws, found, seen)
          raws.each do |raw|
            resolved = resolver.resolve(owner, raw)
            names = resolved.is_a?(String) ? [resolved] : Array(resolved)
            next found[1] << resolver.candidates(owner, raw) if names.empty?

            names.each do |name|
              next if seen[name]

              seen[name] = true
              found[0] << name
              collect_mixins(scope, resolver, name, scope.discovery.discovered_includes[name] || EMPTY_NAMES,
                             found, seen)
            end
          end
        end
      end

      EMPTY_NAMES = [].freeze
      private_constant :EMPTY_NAMES

      # A class's direct project ancestors, as the breadth-first walks queued them: its includes and prepends in
      # `includes_of` order (unless `mixins` is false), then its superclass, each resolved as the method walks
      # resolve a name. `Scope#enqueue_ancestors`, kept for the plugin surface, reads this.
      def self.direct_ancestors(scope, name, mixins)
        resolver = Resolver.new(scope, :methods, flavor_bucket(scope.discovery, :methods))
        return MasterOrder.direct_edges(scope, resolver, name) if mixins

        resolved = resolver.resolve_one(name, scope.discovery.discovered_superclasses[name])
        resolved ? [resolved] : EMPTY_NAMES
      end

      # {MasterOrder}'s memo: one value per key in the flavor's bucket.
      def self.master_memo(scope, flavor, key)
        bucket = flavor_bucket(scope.discovery, flavor)
        memo = bucket[:master]
        return memo[key] if memo.key?(key)

        memo[key] = yield(Resolver.new(scope, flavor, bucket))
      end

      # The linearisation itself, in one world: Ruby's skip rule (`retro: false`), or every skipped insertion
      # made anyway (`retro: true`). Each node's chain is memoised in the flavor's bucket per world (a module's
      # chain is the same whichever class includes it) unless its computation met a cycle, whose answer depends
      # on where the cycle was entered.
      class Builder # rubocop:disable Metrics/ClassLength
        EMPTY = [].freeze
        RETRO_OVER_BUDGET = :rigor_retro_over_budget
        EMPTY_LIN = [EMPTY, EMPTY, EMPTY, 0, false, true].freeze
        private_constant :EMPTY, :EMPTY_LIN, :RETRO_OVER_BUDGET

        # What one node's computation met, handed up to the computation that asked for it: how many forks it
        # counted (see {ResolutionChain#settle}), whether a node on it has mixin edges whose order is not a
        # fact (`unsettled`), and whether it met a cycle or the depth budget (so it is not memoised).
        Frame = Struct.new(:forks, :incomplete, :unsettled, :retro_ok) do
          def absorb(forks, unsettled, retro_ok)
            self.forks += forks
            self.unsettled ||= unsettled
            self.retro_ok &&= retro_ok
          end
        end
        private_constant :Frame

        def initialize(scope, flavor, bucket, retro: false)
          @scope = scope
          @flavor = flavor
          @bucket = bucket
          @retro = retro
          @discovery = scope.discovery
          @resolver = Resolver.new(scope, flavor, bucket)
          # Per memo table: a module's singleton chain reaches its OWN instance chain through `extend self`,
          # which is not a cycle.
          @stacks = {}
          @frames = []
          @deep = false
        end

        # The chain for `root`, carrying its retro world when the skip rule skipped anything on the way.
        def chain(root, side)
          entries, starts, classes, forks, unsettled, retro_ok = lin_for(root, side)
          retro = build_retro(root, side) if forks == 1 && retro_ok && !unsettled && !@retro
          cut_at = cut_position(entries)
          return whole_chain(root, side, entries, starts, classes, [forks, unsettled], retro) if cut_at.nil?

          # Keep the prefix for first-definer reads, and only the levels that end inside it.
          complete = starts.count { |start| start < cut_at }
          complete -= 1 if (starts[complete] || entries.size) > cut_at
          ResolutionChain.new(root: root, side: side, entries: entries.first(cut_at).freeze,
                              level_starts: starts.first(complete).freeze,
                              level_classes: classes.first(complete).freeze,
                              levels_end: complete.zero? ? 0 : (starts[complete] || cut_at), truncated: true,
                              forks: forks, unsettled: unsettled, retro: retro)
        end

        private

        def whole_chain(root, side, entries, starts, classes, (forks, unsettled), retro)
          ResolutionChain.new(root: root, side: side, entries: entries, level_starts: starts,
                              level_classes: classes, levels_end: entries.size, truncated: @deep, forks: forks,
                              unsettled: unsettled, retro: retro)
        end

        def lin_for(root, side) = side == :singleton ? singleton_lin(root, 0) : instance_lin(root, 0)

        # The retro world, built only for a chain with exactly one skip (two or more settle to master without
        # it) and abandoned — nil, which settles to master — once it holds more than {LIMIT} project entries.
        # A retro world repeats every skipped module, so a deep diamond grows it geometrically where the
        # chain itself stays small.
        def build_retro(root, side)
          catch(RETRO_OVER_BUDGET) { Builder.new(@scope, @flavor, @bucket, retro: true).chain(root, side) }
        end

        def guard_retro(entries)
          return unless @retro && entries.size > LIMIT

          throw RETRO_OVER_BUDGET if entries.count { |entry| !entry.external? } > LIMIT
        end

        # The index of the first project entry past {LIMIT}, or nil when the chain fits.
        def cut_position(entries)
          seen = 0
          entries.each_with_index do |entry, index|
            next if entry.external?

            seen += 1
            return index if seen > LIMIT
          end
          nil
        end

        def instance_lin(name, depth)
          memoised(@retro ? :lin_instance_retro : :lin_instance, name, depth) { compute_instance(name, depth) }
        end

        def singleton_lin(name, depth)
          memoised(@retro ? :lin_singleton_retro : :lin_singleton, name, depth) { compute_singleton(name, depth) }
        end

        def memoised(table, name, depth)
          memo = (@bucket[table] ||= {})
          cached = memo[name]
          if cached
            # A memoised chain's forks are the asker's too.
            @frames.last&.absorb(cached[3], cached[4], cached[5])
            return cached
          end

          # A cycle (`class Foo < Foo` resolved inside its own namespace) or a hierarchy deeper than the budget
          # contributes nothing past that point, and the chains computed while it did are not memoised: they
          # depend on where the walk entered.
          stack = (@stacks[table] ||= [])
          if stack.include?(name) || depth > LIMIT
            @deep ||= depth > LIMIT
            @frames.last&.incomplete = true
            return EMPTY_LIN
          end

          frame = Frame.new(0, false, false, true)
          @frames.push(frame)
          stack.push(name)
          entries, starts, classes = yield
          stack.pop
          @frames.pop
          lin = [entries, starts, classes, frame.forks, frame.unsettled, frame.retro_ok].freeze
          memo[name] = lin unless frame.incomplete
          hand_up(frame)
          lin
        end

        def hand_up(frame)
          parent = @frames.last
          return if parent.nil?

          parent.absorb(frame.forks, frame.unsettled, frame.retro_ok)
          parent.incomplete ||= frame.incomplete
        end

        def compute_instance(name, depth)
          # `discovered_includes` already carries the prepended names, so it counts every instance-side edge once.
          mark_unsettled(name, :include, (@discovery.discovered_includes[name] || EMPTY).size)
          entries = [project_entry(name, :instance)]
          super_lin = superclass_lin(name, :instance, depth)
          entries.concat(super_lin[0])
          prepends = @discovery.discovered_prepends[name] || EMPTY
          boundary = prepend_all(entries, name, prepends, depth)
          includes = @discovery.discovered_includes[name] || EMPTY
          super_start = include_all(entries, name, includes, prepends, depth, boundary)
          finish(entries, name, super_lin, super_start)
        end

        def compute_singleton(name, depth)
          mark_unsettled(name, :extend, (@discovery.discovered_extends[name] || EMPTY).size)
          entries = [project_entry(name, :singleton)]
          super_lin = superclass_lin(name, :singleton, depth)
          entries.concat(super_lin[0])
          extends = @discovery.discovered_extends[name] || EMPTY
          super_start = include_all(entries, name, extends, EMPTY, depth, [0, 1])
          finish(entries, name, super_lin, super_start)
        end

        # Marks the node being computed unsettled when the order of its mixin edges on `kind` is not a fact
        # (`DiscoveryIndex#unpositioned_mixins`: an edge written in a conditional, a method, a block or a hook,
        # or a call the walk cannot record, `"*"`), or when its class is declared in more than one file and
        # has two or more such edges, whose order across the files is load order. A node's unsettled state
        # taints every chain that draws on it, so a concern's `included do` edges taint every includer.
        def mark_unsettled(name, kind, edge_count)
          listed = @discovery.unpositioned_mixins[name]&.dig(kind)
          @frames.last.unsettled = true if (listed && !listed.empty?) || (edge_count >= 2 && multi_file?(name))
        end

        def multi_file?(name)
          sites = @discovery.discovered_class_sources[name]
          !sites.nil? && sites.size >= 2
        end

        def finish(entries, name, super_lin, super_start)
          starts = [0]
          super_lin[1].each { |start| starts << (start + super_start) }
          classes = [name].concat(super_lin[2])
          [entries.freeze, starts.freeze, classes.freeze]
        end

        # The superclass's own chain on `side`, or a one-entry chain holding it as an external.
        def superclass_lin(name, side, depth)
          raw = @discovery.discovered_superclasses[name]
          return EMPTY_LIN if raw.nil?

          resolved = resolve(name, raw)
          if resolved.is_a?(String)
            side == :singleton ? singleton_lin(resolved, depth + 1) : instance_lin(resolved, depth + 1)
          else
            # A class the project declares that the `:methods` predicate does not admit (one that only `extend`s)
            # is external here, so its extended modules vanish from the singleton chain and a fork among them
            # goes uncounted. That is a hole in what the chain can see, not an order fork, so it settles to
            # master with the weight of two.
            @frames.last.forks += 2 if side == :singleton && declared_class?(name, raw)
            [[external_entry(name, raw, side, true)].freeze, [0].freeze, [nil].freeze, 0, false, true].freeze
          end
        end

        def declared_class?(owner, raw)
          @scope.ancestor_name_candidates(owner, raw).any? do |candidate|
            @discovery.discovered_extends.key?(candidate)
          end
        end

        # Inserts every prepend, in statement order (the table stores search order, nearest first), ahead of
        # the class, and returns `[origin, super_start]` — where the class itself now sits and where its
        # superclass's entries begin. Ruby skips a module already in the prepend region (a fork: the module is
        # present through a second route); the retro world inserts it again. A sub-chain entry other than the
        # prepended module that the class or its superclass already carries is a fork too (the prepended
        # module's own includes may have run before or after), and the tables record `include M; prepend M`
        # exactly as a plain `prepend M`. A direct prepend of the module itself is always inserted, in Ruby and
        # here, so it forks nothing.
        def prepend_all(entries, owner, prepends, depth)
          origin = 0
          super_start = 1
          # The table holds every statement, nearest first: a same-owner repeat is a no-op in Ruby (the first
          # statement wins), so it is dropped here rather than met as a fork.
          prepends.reverse.uniq.each do |raw|
            modules = Array(resolve(owner, raw))
            each_mixin_chain(owner, raw, depth) do |sub|
              point = -1
              sub.each do |entry|
                found = entries.index(entry)
                if found && found < origin && !@retro
                  fork_without_retro
                  point = found if found > point
                else
                  fork_without_retro if found && !@retro && !modules.include?(entry.name)
                  entries.insert(point + 1, entry)
                  point += 1
                  origin += 1
                  super_start += 1
                end
              end
            end
            guard_retro(entries)
          end
          [origin, super_start]
        end

        # Inserts every name in `mixins` that `skip` does not hold, in statement order, after the class, and
        # returns where the superclass's entries now begin. Ruby skips a module already anywhere in the chain;
        # that is a fork (the module is present through a second route), and the retro world inserts it
        # again. Exactly one fork, at or after the class, on the last entry of the sub-chain being inserted, is
        # the one shape whose Ruby worlds are exactly two: the skip made or the insertion made.
        def include_all(entries, owner, mixins, skip, depth, boundary)
          origin, super_start = boundary
          mixins.reverse_each do |raw|
            next if skip.include?(raw)

            each_mixin_chain(owner, raw, depth) do |sub|
              point = origin
              sub.each_with_index do |entry, index|
                found = @retro ? nil : entries.index(entry)
                if found
                  @frames.last.forks += 1
                  @frames.last.retro_ok = false unless found >= origin && index == sub.size - 1
                  point = found if found > point && found < super_start
                else
                  entries.insert(point + 1, entry)
                  point += 1
                  super_start += 1
                end
              end
            end
            guard_retro(entries)
          end
          super_start
        end

        # A fork whose second Ruby world is not "the insertion made anyway": the chain settles to master.
        def fork_without_retro
          @frames.last.forks += 1
          @frames.last.retro_ok = false
        end

        # Yields the instance chain of the module `raw` names from `owner` — once per class an ambiguous
        # spelling can name under the `:arity` flavor — or a one-entry chain holding it as an external.
        def each_mixin_chain(owner, raw, depth)
          resolved = resolve(owner, raw)
          case resolved
          when String then yield instance_lin(resolved, depth + 1)[0]
          when Array then resolved.each { |name| yield instance_lin(name, depth + 1)[0] }
          else yield [external_entry(owner, raw, :instance, false)]
          end
        end

        def resolve(owner, raw) = @resolver.resolve(owner, raw)

        def project_entry(name, side)
          by_side = (@bucket[:interned][side] ||= {})
          by_side[name] ||= Entry.new(name, side, nil, nil, false)
        end

        def external_entry(owner, raw, side, superclass_edge)
          by_edge = ((@bucket[:externals][side] ||= {})[superclass_edge] ||= {})
          by_owner = (by_edge[owner] ||= {})
          by_owner[raw] ||= Entry.new(nil, side, raw, @scope.ancestor_name_candidates(owner, raw).freeze,
                                      superclass_edge)
        end
      end
      private_constant :Builder
    end
  end
end
