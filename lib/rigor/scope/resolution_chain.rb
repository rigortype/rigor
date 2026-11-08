# frozen_string_literal: true

require_relative "../typing_state"
require_relative "../memo_audit"

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
      # ambiguous spelling), and `superclass_edge` says it was reached through a superclass edge. `owner` names
      # the class or module whose edge an external entry is (#1698: Ruby resolves an `include`'s argument with
      # that body as the innermost cref, a namespace `candidates` leaves out); it is nil on a project entry.
      # `last_segment` is the unqualified name a project entry files its negative class edge under, computed once
      # when the entry is interned.
      Entry = Data.define(:name, :side, :raw, :candidates, :superclass_edge, :last_segment, :owner) do
        def external? = name.nil?
      end

      # How many project entries a chain may hold before it is cut (ADR-41 WD4). The breadth-first walks
      # counted visited project nodes against the same number.
      LIMIT = 100

      # ADR-119 WD2 — what marked a chain unsettled, one per marking node and side: `node` is the class or
      # module whose mixin edges' order is not a fact, `kind` the side read (`:include` or `:extend`), `listed`
      # the entries `DiscoveryIndex#unpositioned_mixins` lists for it (`"*"` included), and `multi_file` whether
      # the multi-file rule fired (two or more files declare it and it has two or more edges on that side).
      # Interned per `[node, kind]` in the flavor's bucket, so equal marks are one object. Kind `:extend_hook`
      # (#1730, listing `"*"`) marks a node a module it extends may mix into through a hook; it is not an order mark
      # ({#order_marks}). Kind `:include_hook` (#1592, listing `"*"` and `"?"`) marks a class object a module it
      # includes or prepends may extend, through a hook, with a module no table names; nor is it. Kind `:hook_order`
      # (#1592, listing nothing) marks a class object whose own `extend`s and hook-extended modules have no known
      # order between them: the fork it counts already settles the chain, and the mark tells the typing read why.
      Mark = Data.define(:node, :kind, :listed, :multi_file)

      # The mark kinds that are not order marks.
      HOOK_MARK_KINDS = %i[extend_hook include_hook hook_order].freeze

      NO_MARKS = [].freeze

      attr_reader :root, :side, :entries, :level_starts, :level_classes, :flavor

      # rubocop:disable-next Metrics/ParameterLists
      def initialize(root:, side:, entries:, level_starts:, level_classes:, levels_end:, truncated:, forks: 0,
                     marks: NO_MARKS, flavor: :methods, retro: nil)
        @root = root
        @side = side
        @entries = entries
        @level_starts = level_starts
        @level_classes = level_classes
        @levels_end = levels_end
        @truncated = truncated
        @forks = forks
        @marks = marks
        @flavor = flavor
        @retro = retro
        @memo = {} # the chain is frozen; this table is not, and holds {#levels}
        freeze
      end

      # True when the chain was cut at {LIMIT} project entries: a reader that found nothing on it cannot tell
      # "no definer" from "a definer past the cut", which is budget uncertainty, not absence.
      def truncated? = @truncated

      # ADR-129 G2 — the chain's content, for the memo audit: a recomputation builds a new chain object, which
      # equals the stored one field for field (its retro world included) when the memo's key holds every input.
      def audit_signature
        [@root, @side, @entries, @level_starts, @level_classes, @levels_end, @truncated, @forks, @marks, @flavor,
         @retro&.audit_signature]
      end

      # How many forks the replay met while this chain was built, counted across every module sub-chain it drew
      # on (a memoised sub-chain hands its own count up): each entry that reached the chain by a second route.
      # An over-count only ever sends a reader to master's answer.
      attr_reader :forks
      alias skip_count forks

      # True when a class on the chain has mixin edges whose order the tables cannot vouch for
      # (`DiscoveryIndex#unpositioned_mixins`, or a class declared in several files with several edges).
      def unsettled? = !order_marks.empty?

      # The marks that make the chain's ORDER doubtful. An `:extend_hook` mark (#1730) says only that an extended
      # module's hook may have mixed something in that the chain does not list: it makes a candidate-set read
      # `:unknown` and {#wildcard_mixin?} true, and leaves every other reader on the chain's own order. Sending
      # those readers to master's order would answer a constant lookup breadth-first, which is wrong for the
      # #1567 shape on every class that extends such a module.
      def order_marks
        @memo[:order_marks] ||= @marks.reject { |mark| HOOK_MARK_KINDS.include?(mark.kind) }.freeze
      end

      # True when a class on the chain records a mixin the tables cannot name (`"*"`: an `include` of a
      # non-constant, or a call the walk cannot record), so the chain may hold a module it does not list.
      def wildcard_mixin? = @marks.any? { |mark| mark.listed.include?(Relevance::WILDCARD) }

      # Issue #2991 — true when a class on the chain mixes in a module the tables do not record under any name
      # (`include(*MODS)`, `include helper`, a hook's `base.include M`, an unrecorded `self.include M`): the chain's SET
      # of modules is unknown, not only its order. Every such mark is also a {#wildcard_mixin?} one; `include M;
      # prepend M` taints the order alone.
      def unnamed_mixin? = @marks.any? { |mark| mark.listed.include?(Relevance::UNNAMED) }

      # Issue #1592 — whether a class object on the chain has hook-extended modules whose order against its own
      # `extend`s, or among themselves, is not a fact ({Builder#singleton_mixins}).
      def hook_order_marked? = @marks.any? { |mark| mark.kind == :hook_order }

      # The chain's retro world ({#settle}), or nil when it has none.
      def retro_world = @retro

      # Issue #1592 — the class objects on a singleton chain that a module they include or prepend may extend, through
      # a hook, with a module no table names: that module sits right after the class object's own entry.
      def hook_open_nodes
        @memo[:hook_open_nodes] ||= @marks.filter_map { |mark| mark.node if mark.kind == :include_hook }.freeze
      end

      # Issue #2991 — `[[node, raw], …]`: the module names the chain's marks list beside the wildcard, each with the
      # class or module it was written on. An unrecorded `self.include M` or receiverless `send(:include, M)` lists `M`
      # here and in no include table, so a reader that asks the tables for a method also asks these.
      def listed_mixins
        @memo[:listed_mixins] ||= @marks.flat_map do |mark|
          mark.listed.filter_map { |raw| [mark.node, raw] unless MARKERS.include?(raw) }
        end.uniq.freeze
      end

      MARKERS = ["*", "?"].freeze # Relevance::WILDCARD and Relevance::UNNAMED
      private_constant :MARKERS

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
      # ADR-119 WD2 — `unknown_for: name` is the candidate-set read's option (only {Inference::DefinerResolution}
      # passes it): a `:master` verdict becomes `:unknown`, since a reader that can decline has no use for the
      # replaced walk's answer, and a chain whose every mark is discharged for `name` (see {Relevance}) and that
      # has no fork is read as settled. Without the option the verdict is never `:unknown`: the readers that
      # compare it with `:master` would read a leaked `:unknown` as `:chain`.
      def settle(scope, answer, owner: nil, unknown_for: nil, &)
        # The verdict depends on EVERY node of the chain (a fork, an unpositioned edge, a second declaring file),
        # and `:master` changes the answer, so the entries past the answer are dependencies whichever way it
        # goes; `search` files only the entries ahead of an answer. `owner` names the entry that answered.
        record_beyond(scope, owner, unknown_for.nil?)
        return settle_unknown(scope, answer, unknown_for, &) unless unknown_for.nil?
        return :master unless order_marks.empty?

        case @forks
        when 0 then :chain
        when 1 then !@retro.nil? && answer == yield(@retro) ? :chain : :master
        else :master
        end
      end

      # {#settle} under `unknown_for:`: a mark that is not discharged for the name, a fork the marks overlap
      # (relevance is argued for the fork-free case only), a second fork or a retro world that answers
      # otherwise are all `:unknown`. The retro world is the one built when the chain had exactly one fork and
      # no mark; a chain with a fork is never narrowed, so none is built on demand.
      def settle_unknown(scope, answer, name)
        return settle_marked(scope, name) unless @marks.empty?

        case @forks
        when 0 then :chain
        when 1 then !@retro.nil? && answer == yield(@retro) ? :chain : :unknown
        else :unknown
        end
      end

      # A marked chain stands only with no fork and every mark discharged for the name.
      def settle_marked(scope, name)
        fork_free = @forks.zero?
        return :unknown unless fork_free && @marks.all? { |mark| Relevance.discharged?(scope, self, mark, name) }

        :chain
      end
      private :settle_marked
      private :settle_unknown

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
        if recording
          record_head(scope, start, side)
          record_extend_hooks(scope)
          record_include_hooks(scope)
        end
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
        (stop || @entries.size).times { |index| ResolutionChain.record_entry(scope, @entries[index], side) }
        record_extend_hooks(scope)
        record_include_hooks(scope)
      end

      # Issue #2689 — the negative edge a method-walk MISS owes each EXTERNAL entry: `class:<last segment>` of the name
      # as written. An external entry is an ancestor the project declares with no methods (the usual empty
      # `ApplicationRecord`) or not at all yet, so the walk looked nothing up there; a later file that declares it
      # with the method turns the miss, and the declaration appearing is the one event that file fires. A core or gem
      # ancestor (`StandardError`, `Comparable`) files its key too, which fires only on a file that declares a
      # constant of that name. Recorded only on a miss: a hit's answer cannot be turned by an entry gaining a method.
      def record_external_absence
        return unless Analysis::DependencyRecorder.active?

        @entries.each do |entry|
          Analysis::DependencyRecorder.read_last_segment(:class, entry.raw.to_s) if entry.external?
        end
      end

      # What a {#settle} verdict adds to what the search already filed. The search files the root and every entry
      # AHEAD of the answer; entries strictly after it matter only through the verdict (a fork or an unpositioned
      # edge there sends the reader to master's answer), so they are filed here, and only where master's answer
      # could differ from the chain's:
      #
      # - the answer is the root's own entry and nothing is prepended (the root heads its chain), and the verdict
      #   is `:chain` or `:master` (`master_only`): master's first candidate is the root too, so no verdict can
      #   move it and nothing more is filed. Under `unknown_for:` a mark or a `"*"` elsewhere on the chain turns
      #   it `:unknown`, so the rest of the chain is filed as for any other answer;
      # - otherwise every entry after the answer (the whole chain when `owner` names none) files its class edge
      #   and, for a project entry, the negative class edge on its unqualified name, so a NEW file declaring or
      #   reopening it re-checks the reader. An external entry files only the sites of the names it can denote,
      #   and every external on the chain files its hook edges ({#record_hooks}, #1641).
      #
      # What is filed is a function of this chain, the entry the filing starts from and the discovery index the
      # sites are read from, so a consumer that settles the same chain from the same entry again (the common case:
      # one hierarchy read at every call site of a file) files it once ({Analysis::DependencyRecorder.file_chain_once},
      # #1590). The recorded edges are the same; only the repeated filing is gone.
      def record_beyond(scope, owner, master_only)
        return unless Analysis::DependencyRecorder.active?
        return if master_only && !owner.nil? && owner == @root && @entries.first&.name == @root

        start = owner.nil? ? nil : @entries.index { |entry| entry.name == owner }
        Analysis::DependencyRecorder.file_chain_once(self, start, scope.discovery) { file_beyond(scope, start) }
        record_hooks(scope)
        record_extend_hooks(scope)
        record_include_hooks(scope)
      end
      private :record_beyond

      def file_beyond(scope, start)
        ResolutionChain.record_class(scope, @root) if start.nil?
        index = start.nil? ? 0 : start + 1
        while index < @entries.size
          entry = @entries[index]
          ResolutionChain.record_entry(scope, entry, nil)
          Analysis::DependencyRecorder.read_missing(:class, entry.last_segment) unless entry.external?
          index += 1
        end
      end
      private :file_beyond

      # #1641 — the hook edges of every EXTERNAL entry on the chain, ahead of the answer or past it. A project file
      # that gives an external module a hook (`module Comparable; def self.included(base) = base.prepend(P); end`)
      # can put a definer ahead of the answer wherever the module sits, and a candidate-set read declines on it
      # (the hook's mixin lists `"*"` on the module). The entry's class edges are the sites of the names it can
      # denote, which a NEW file is not among, and a negative class edge on its name would re-check every reader of
      # `Kernel` or `Enumerable` on any reopening. So each candidate name files the negative method edge of every
      # {Relevance::HOOKS} name on its singleton side (`method:Comparable.included`, the key a new `def
      # self.included` satisfies); a file adding any other method to the module re-checks nothing, and once the
      # module is declared its sites carry later edits and the removal. #1661 — each name also files `mixin:<name>`,
      # which `IncrementalSession#mark_affected` fires when the module's unpositioned mixin edges move: a new file
      # that taints it (`module Comparable; include(*MODS); end`) without a hook. The key is the qualified candidate,
      # the spelling the chain resolves a project entry by. The unpositioned table may key the owner by a relative
      # spelling (`Constants` inside `class File`), so the producer also fires every recorded `mixin:` key ending in
      # `::<owner>` (`IncrementalSession#mixin_keys`); a taint on a project `Foo::Base` still re-checks no reader of
      # an external `Lib::Base`. An ambiguous spelling has no candidate and files none: no project module can resolve
      # it, so no taint can mark it. The edges are a function of the chain alone, so a consumer files them once per
      # chain ({Analysis::DependencyRecorder.file_chain_once}, #1590). A hook written another way — an instance `def
      # included` in a module extended onto the external, a `define_singleton_method(:included)` — satisfies no such
      # key and is not seen.
      def record_hooks(scope)
        externals = (@memo[:externals] ||= @entries.select(&:external?).freeze)
        return if externals.empty?

        Analysis::DependencyRecorder.file_chain_once(self, :hooks, scope.discovery) do
          externals.each do |entry|
            entry.candidates.each { |name| Analysis::DependencyRecorder.read_keys(ResolutionChain.external_keys(name)) }
          end
        end
      end
      private :record_hooks

      # #1730 — the edges of the {Builder#extend_hook_taint} decision: an instance chain's project entries may carry
      # a `"*"` mark because a module one of them `extend`s has a hook that mixes into the extender, and the
      # module is often declared in a file the chain records nothing of. Each such module the decision read files
      # its class edges (an edit to its hook moves its declaration signature) and the negative method edges of
      # the hooks the decision reads ({ResolutionChain.extend_hook_keys}), which a NEW file reopening the module
      # to add a hook satisfies; a spelling no project module answers files the singleton hook keys of each name
      # it can denote, as {#record_hooks} does. Filed once per consumer and chain.
      def record_extend_hooks(scope)
        return unless @side == :instance

        targets = (@memo[:extend_targets] ||= ResolutionChain.extend_targets(scope, @flavor, @entries))
        return if targets.empty?

        Analysis::DependencyRecorder.file_chain_once(self, :extend_hooks, scope.discovery) do
          targets.each do |raw, resolved, candidates|
            Analysis::DependencyRecorder.read_last_segment(:class, raw)
            if resolved
              ResolutionChain.record_class(scope, resolved)
              Analysis::DependencyRecorder.read_keys(ResolutionChain.extend_hook_keys(resolved))
            else
              candidates.each { |name| Analysis::DependencyRecorder.read_keys(ResolutionChain.hook_keys(name)) }
            end
          end
        end
      end
      private :record_extend_hooks

      # #1592 — the edges of the {Builder#hook_extensions} read: a singleton chain draws, for every class on it, the
      # modules that class's direct mixins' hooks extend it with, and the mixins are declared in files the chain's own
      # entries record nothing of. Each resolved mixin files its class edges and the negative `mark:` edge on its name,
      # which an edit adding or dropping a hook-extend entry fires; every mixin, and every module a hook extends by
      # name, files the negative class edge on its last segment, which a NEW file declaring or reopening it fires.
      # Filed once per consumer and chain.
      def record_include_hooks(scope)
        return unless @side == :singleton

        edges = (@memo[:include_hook_edges] ||= ResolutionChain.include_hook_edges(scope, @flavor, @level_classes))
        return if edges.empty?

        Analysis::DependencyRecorder.file_chain_once(self, :include_hooks, scope.discovery) do
          edges.each do |kind, name|
            ResolutionChain.record_class(scope, name) if kind == :mixin
            Analysis::DependencyRecorder.read_last_segment(:mark, name) if kind == :mixin
            Analysis::DependencyRecorder.read_last_segment(:class, name)
          end
        end
      end
      private :record_include_hooks

      # `[[:mixin, resolved name] | [:spelling, raw], …]`: the direct mixins of every class on a singleton chain, and
      # the modules the resolved ones' hooks extend by name ({Builder#hook_extensions}).
      def self.include_hook_edges(scope, flavor, classes)
        resolver = resolver_for(scope, flavor)
        discovery = scope.discovery
        classes.each_with_object([]) do |klass, out|
          next if klass.nil?

          (discovery.discovered_includes[klass] || EMPTY_NAMES).uniq.each do |raw|
            mixin = resolver.resolve_declared(klass, raw)
            next out << [:spelling, raw].freeze if mixin.nil?

            out << [:mixin, mixin].freeze
            hook_extend_keys(discovery, mixin).each { |key| out << [:spelling, key[1]].freeze }
          end
        end.uniq.freeze
      end

      # The `[ENVELOPE_HOOK_EXTEND_KIND, written, hook]` keys of a module's envelope bucket, in recording order.
      def self.hook_extend_keys(discovery, name)
        bucket = discovery.discovered_parameter_envelopes[name]
        return EMPTY_NAMES if bucket.nil?

        bucket.each_key.select { |key| key.is_a?(Array) && key.first == DiscoveryIndex::ENVELOPE_HOOK_EXTEND_KIND }
      end

      # The hooks that let a module `extend`ed onto N reshape N's INSTANCE side (#1730): its singleton `extended` /
      # `extend_object` run against N at the `extend` and may mix into N; its instance `included` /
      # `append_features` / `prepended` / `prepend_features` / `inherited` become N's own singleton hooks and run
      # against N's includers, prependers and subclasses, which the mark on N reaches through their chains.
      SINGLETON_EXTEND_HOOKS = %i[extended extend_object].freeze
      INSTANCE_EXTEND_HOOKS = %i[included append_features prepended prepend_features inherited].freeze

      # ADR-129 WD1 — three interning Memos, not run-scoped: a value is a frozen Array of frozen Strings built from the
      # name and frozen constants alone, so an entry is fixed once written and holds nothing of a run. Each hit goes
      # through `MemoAudit.check`, and an audit recomputation bypasses the table.
      EXTEND_HOOK_KEYS = TypingState.memo(
        :resolution_chain_extend_hook_keys,
        audit: "extend hook keys",
        reason: "keyed on the module name; a frozen Array of frozen Strings built from the name and the extend-hook " \
                "constants alone"
      )
      HOOK_KEYS = TypingState.memo(
        :resolution_chain_hook_keys,
        audit: "hook keys",
        reason: "keyed on the class name; a frozen Array of frozen Strings built from the name and " \
                "Relevance::HOOKS alone"
      )
      EXTERNAL_KEYS = TypingState.memo(
        :resolution_chain_external_keys,
        audit: "external keys",
        reason: "keyed on the class name; HOOK_KEYS' answer plus one frozen String built from the name"
      )
      private_constant :EXTEND_HOOK_KEYS, :HOOK_KEYS, :EXTERNAL_KEYS

      # The frozen negative method keys of `name`'s {SINGLETON_EXTEND_HOOKS} and {INSTANCE_EXTEND_HOOKS}.
      def self.extend_hook_keys(name)
        return build_extend_hook_keys(name) if Inference::MemoAudit.enabled? && Inference::MemoAudit.suspended?

        state = TypingState.current
        table = (state[EXTEND_HOOK_KEYS] ||= {})
        stored = table[name]
        if stored.nil?
          return table[name] = Inference::MemoAudit.key_audit("extend hook keys") { build_extend_hook_keys(name) }
        end

        Inference::MemoAudit.check("extend hook keys", stored, name) { build_extend_hook_keys(name) }
      end

      def self.build_extend_hook_keys(name)
        (
          SINGLETON_EXTEND_HOOKS.map { |hook| "method:#{name}.#{hook}".freeze } +
          INSTANCE_EXTEND_HOOKS.map { |hook| "method:#{name}##{hook}".freeze }
        ).freeze
      end

      # Whether extending `name` may mix modules into the extender's instance side, or into its includers' (#1730):
      # `name` records a mixin it cannot name on its own instance side (`"*"`, which a hook's `base.include X` or
      # `base.class_eval { … }` lists on the hook's module) and defines one of the hooks that would run it there.
      def self.extend_reshapes_instance?(scope, name)
        listed = scope.discovery.unpositioned_mixins[name]&.dig(:include)
        return false unless listed&.include?(Relevance::WILDCARD)

        defines_any?(scope.discovered_singleton_def_nodes[name], SINGLETON_EXTEND_HOOKS) ||
          defines_any?(scope.discovered_def_nodes[name], INSTANCE_EXTEND_HOOKS)
      end

      # Read off the def-node tables: the existence table does not carry a module's own instance hook once the
      # extend fold has copied it onto the extender's singleton.
      def self.defines_any?(defs, hooks)
        !defs.nil? && hooks.any? { |hook| defs.key?(hook) }
      end

      # `[[spelling, resolved name or nil, candidate names], …]`: every module the project entries of an instance chain
      # `extend`, as {Builder#extend_hook_taint} resolved them.
      def self.extend_targets(scope, flavor, entries)
        resolver = resolver_for(scope, flavor)
        extends = scope.discovery.discovered_extends
        entries.each_with_object([]) do |entry, out|
          next if entry.external? || entry.side != :instance

          (extends[entry.name] || EMPTY_NAMES).each do |raw|
            resolved = resolver.resolve_one(entry.name, raw)
            out << [raw, resolved, resolved ? EMPTY_NAMES : resolver.candidates(entry.name, raw)].freeze
          end
        end.uniq.freeze
      end

      # The frozen `method:Name.hook` negative keys of `name`'s {Relevance::HOOKS}, built once per name.
      def self.hook_keys(name)
        return build_hook_keys(name) if Inference::MemoAudit.enabled? && Inference::MemoAudit.suspended?

        state = TypingState.current
        table = (state[HOOK_KEYS] ||= {})
        stored = table[name]
        return table[name] = Inference::MemoAudit.key_audit("hook keys") { build_hook_keys(name) } if stored.nil?

        Inference::MemoAudit.check("hook keys", stored, name) { build_hook_keys(name) }
      end

      def self.build_hook_keys(name) = Relevance::HOOKS.map { |hook| "method:#{name}.#{hook}".freeze }.freeze

      # {hook_keys} plus the `mixin:<name>` key an external entry files for its unpositioned mixins (#1661).
      def self.external_keys(name)
        return build_external_keys(name) if Inference::MemoAudit.enabled? && Inference::MemoAudit.suspended?

        state = TypingState.current
        table = (state[EXTERNAL_KEYS] ||= {})
        stored = table[name]
        if stored.nil?
          return table[name] = Inference::MemoAudit.key_audit("external keys") { build_external_keys(name) }
        end

        Inference::MemoAudit.check("external keys", stored, name) { build_external_keys(name) }
      end

      def self.build_external_keys(name) = (hook_keys(name) + ["mixin:#{name}".freeze]).freeze
      private_class_method :build_extend_hook_keys, :build_hook_keys, :build_external_keys

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

      # Issue #2979 — the position of the first entry after `name`'s own that is a true ancestor of it, or nil when
      # `name` has no entry on `side`. The entries of the names bound to the same class object
      # (`K = Struct.new("Named", …)`) follow `name`'s own directly, and a `def` under one of them is a redefinition
      # of the class's method, not an override, so a reader of "the entries after the class" starts past them.
      def ancestors_start(scope, name, side = @side)
        own = index_of(name, side)
        return nil if own.nil?

        twins = DiscoveryIndex.same_class_names(scope.discovery.discovered_parameter_envelopes[name])
        start = own + 1
        start += 1 while twins_entry?(@entries[start], twins, side)
        start
      end

      def twins_entry?(entry, twins, side)
        !twins.empty? && !entry.nil? && entry.side == side && twins.include?(entry.name)
      end
      private :twins_entry?

      # A LEVEL is one superclass step: the class (or its singleton) with the modules inserted around it,
      # before the next superclass's entries begin. `level_classes[k]` is that class, or nil for a level that
      # is an external superclass. Only COMPLETE levels are counted — a level the {LIMIT} cut in half is not.
      def level_count = @level_starts.size

      def level_entries(index)
        finish = @level_starts[index + 1] || @levels_end
        @entries[@level_starts[index]...finish]
      end

      # Issue #1624 — whether the chain's last class has a superclass the tables cannot name, so ancestors the chain
      # does not list follow it where a chain otherwise ends in the implicit `Object`: a superclass written as an
      # expression (`class K < Struct.new(:a)`, `< Data.define(:a)`, `< Class.new(Base)`, `< pick_base`), which the
      # superclass table records as `nil`, or a class a constant write creates (`K = Class.new(Base)`,
      # `K = Struct.new(:a)`, `K = Data.define(:a)`), which has no superclass entry. The constructor's methods
      # (`members`, the member readers, a block's `def`s) and everything it inherits live in that unlisted part.
      # Every fact read here is filed under the last class's class edge, which a read reaching the tail has passed.
      def opaque_tail?(scope)
        @memo.fetch(:opaque_tail) do
          last = level_count.positive? ? @level_classes[level_count - 1] : nil
          @memo[:opaque_tail] = !last.nil? && ResolutionChain.opaque_superclass?(scope, last)
        end
      end

      def self.opaque_superclass?(scope, name)
        superclasses = scope.discovery.discovered_superclasses
        return superclasses[name].nil? if superclasses.key?(name)

        scope.discovery.discovered_parameter_envelopes[name]&.key?(DiscoveryIndex::ENVELOPE_META_SUPERCLASS_MARK) ||
          !(scope.struct_member_layout(name) || scope.data_member_layout(name)).nil?
      end

      # Each complete level up to the first superclass the project does not declare, as `[class_name,
      # modules, externals]`: the level's class, the project modules around it (each once), and the candidate
      # lists of the ancestors in it the project does not declare — the shape `call.wrong-arity` reads.
      def levels = (@memo[:levels] ||= compute_levels)

      def compute_levels
        out = []
        level_count.times do |index|
          class_name = @level_classes[index]
          break if class_name.nil?

          externals, entries = level_entries(index).partition(&:external?)
          modules = entries.filter_map { |entry| entry.name unless entry.name == class_name && entry.side == @side }
          out << [class_name, modules.uniq.freeze, externals.map(&:candidates).freeze].freeze
        end
        out.freeze
      end
      private :compute_levels

      # ADR-129 WD1 — a run-scoped Memo: one `[discovery, flavors]` slot keyed on the discovery index's identity, the
      # only input a chain reads.
      #
      # ADR-129 G2 — every table of the slot's flavor buckets is audited on a hit under `RIGOR_MEMO_AUDIT=1`, and an
      # audit recomputation reads a fresh, unstored bucket ({.flavor_bucket}), so it reads nothing stored.
      MEMO = TypingState.memo(
        :resolution_chain,
        run_scoped: true,
        audit: ["resolution chain", "resolution chain name", "resolution chain relevance",
                "resolution chain master order", "resolution chain linearisation", "resolution chain mark",
                "resolution chain entry", "resolution chain external entry", "singleton hook verdict"],
        reason: "one slot keyed on the discovery index's identity; a chain is a pure function of that frozen index " \
                "and the flavor"
      )
      private_constant :MEMO

      FLAVORS = %i[methods constants arity].freeze

      # The chain for `class_name` on `side` under `flavor`. Memoised in ONE thread-local slot keyed on the
      # discovery index's identity — the same shape as `ExpressionTyper#class_graph_buckets`: the chain is a
      # pure function of that frozen index, and a store keyed on it would pin every file's index for the run.
      def self.for(scope, class_name, side, flavor)
        raise ArgumentError, "unknown resolution-chain flavor #{flavor.inspect}" unless FLAVORS.include?(flavor)

        bucket = flavor_bucket(scope.discovery, flavor)
        chains = bucket[side]
        cached = chains[class_name]
        if cached.nil?
          return chains[class_name] = Inference::MemoAudit.key_audit("resolution chain") do
            Builder.new(scope, flavor, bucket).chain(class_name, side)
          end
        end
        return cached unless Inference::MemoAudit.enabled?

        Inference::MemoAudit.check("resolution chain", cached.audit_signature, class_name, side) do
          fresh = Analysis::DependencyRecorder.withhold do
            Builder.new(scope, flavor, flavor_bucket(scope.discovery, flavor)).chain(class_name, side)
          end
          fresh.first.audit_signature
        end
        cached
      end

      # The flavor's bucket of memo tables. While an audit recomputation runs ({Inference::MemoAudit.suspended?})
      # every call answers a fresh bucket that is never stored, so the recomputation neither reads nor writes the
      # slot.
      def self.flavor_bucket(discovery, flavor)
        return new_bucket if Inference::MemoAudit.enabled? && Inference::MemoAudit.suspended?

        state = TypingState.current
        slot = state[MEMO]
        unless slot && slot[0].equal?(discovery)
          slot = [discovery, {}]
          state[MEMO] = slot
        end
        slot[1][flavor] ||= new_bucket
      end

      def self.new_bucket
        { instance: {}, singleton: {}, names: {}, interned: {}, externals: {}, master: {}, marks: {} }
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
          unless by_owner.key?(raw)
            return by_owner[raw] = Inference::MemoAudit.key_audit("resolution chain name") { compute(owner, raw) }
          end

          Inference::MemoAudit.check("resolution chain name", by_owner[raw], owner, raw) do
            Analysis::DependencyRecorder.withhold { compute(owner, raw) }.first
          end
        end

        # {#resolve}, with an ambiguous spelling read as unresolved.
        def resolve_one(owner, raw)
          resolved = raw.nil? ? nil : resolve(owner, raw)
          resolved.is_a?(String) ? resolved : nil
        end

        # Issue #1592 — {#resolve_one}, or else the first candidate the project declares at all: a module holding only
        # hooks (`included do extend M end`) is no project class under any flavor, yet its hooks run.
        def resolve_declared(owner, raw)
          resolve_one(owner, raw) ||
            candidates(owner, raw).find { |candidate| @discovery.discovered_class_sources.key?(candidate) }
        end

        def candidates(owner, raw) = @scope.ancestor_name_candidates(owner, raw)

        # Whether `name`, already qualified, is a project class under this flavor.
        def project_name?(name) = project?(name)

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
            @scope.known_user_class?(name) ||
              DiscoveryIndex.declares_surface?(@discovery.discovered_parameter_envelopes[name])
          else
            @scope.known_user_class?(name)
          end
        end
      end
      private_constant :Resolver

      private_class_method :flavor_bucket, :new_bucket

      # {Relevance}'s verdict memo, one table per flavor bucket.
      def self.relevance_memo(scope, flavor)
        flavor_bucket(scope.discovery, flavor)[:relevance] ||= {}
      end

      # The singleton-side hook verdicts' memo (`Inference::DefinerResolution`'s positional decline, ADR-119 WD3),
      # one table per flavor bucket.
      def self.hook_memo(scope, flavor)
        flavor_bucket(scope.discovery, flavor)[:hooks] ||= {}
      end

      # The name resolver of `flavor`, over the same memo the chain builder shares: {Relevance} resolves a
      # mark's listed entry from the node that listed it, exactly as the chain did.
      def self.resolver_for(scope, flavor)
        Resolver.new(scope, flavor, flavor_bucket(scope.discovery, flavor))
      end

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
        unless memo.key?(key)
          return memo[key] = Inference::MemoAudit.key_audit("resolution chain master order") do
            yield(Resolver.new(scope, flavor, bucket))
          end
        end

        Inference::MemoAudit.check("resolution chain master order", memo[key], flavor, key) do
          fresh = flavor_bucket(scope.discovery, flavor)
          Analysis::DependencyRecorder.withhold { yield(Resolver.new(scope, flavor, fresh)) }.first
        end
      end

      # The linearisation itself, in one world: Ruby's skip rule (`retro: false`), or every skipped insertion
      # made anyway (`retro: true`). Each node's chain is memoised in the flavor's bucket per world (a module's
      # chain is the same whichever class includes it) unless its computation met a cycle, whose answer depends
      # on where the cycle was entered.
      class Builder # rubocop:disable Metrics/ClassLength
        EMPTY = [].freeze
        RETRO_OVER_BUDGET = :rigor_retro_over_budget
        EMPTY_LIN = [EMPTY, EMPTY, EMPTY, 0, NO_MARKS, true].freeze
        private_constant :EMPTY, :EMPTY_LIN, :RETRO_OVER_BUDGET

        # What one node's computation met, handed up to the computation that asked for it: how many forks it
        # counted (see {ResolutionChain#settle}), the {Mark}s of the nodes on it whose mixin edges' order is not a
        # fact, and whether it met a cycle or the depth budget (so it is not memoised).
        Frame = Struct.new(:forks, :incomplete, :marks, :retro_ok) do
          # ADR-119 WD2 — mark arrays are frozen and shared: the receiver keeps its array when the other is
          # empty, adopts the other's when it is empty itself, and allocates a union only when both hold marks.
          def absorb(forks, other, retro_ok)
            self.forks += forks
            add_marks(other)
            self.retro_ok &&= retro_ok
          end

          def add_marks(other)
            return if other.empty? || marks.equal?(other)

            self.marks = marks.empty? ? other : (marks | other).freeze
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
          entries, starts, classes, forks, marks, retro_ok = lin_for(root, side)
          order_marked = marks.any? { |mark| !HOOK_MARK_KINDS.include?(mark.kind) }
          retro = build_retro(root, side) if forks == 1 && retro_ok && !order_marked && !@retro
          cut_at = cut_position(entries)
          return whole_chain(root, side, entries, starts, classes, [forks, marks], retro) if cut_at.nil?

          # Keep the prefix for first-definer reads, and only the levels that end inside it.
          complete = starts.count { |start| start < cut_at }
          complete -= 1 if (starts[complete] || entries.size) > cut_at
          ResolutionChain.new(root: root, side: side, entries: entries.first(cut_at).freeze,
                              level_starts: starts.first(complete).freeze,
                              level_classes: classes.first(complete).freeze,
                              levels_end: complete.zero? ? 0 : (starts[complete] || cut_at), truncated: true,
                              forks: forks, marks: marks, flavor: @flavor, retro: retro)
        end

        private

        def whole_chain(root, side, entries, starts, classes, (forks, marks), retro)
          ResolutionChain.new(root: root, side: side, entries: entries, level_starts: starts,
                              level_classes: classes, levels_end: entries.size, truncated: @deep, forks: forks,
                              marks: marks, flavor: @flavor, retro: retro)
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

        def memoised(table, name, depth, &)
          memo = (@bucket[table] ||= {})
          cached = memo[name]
          return absorb_cached(audited_lin(cached, table, name)) if cached

          # A cycle (`class Foo < Foo` resolved inside its own namespace) or a hierarchy deeper than the budget
          # contributes nothing past that point, and the chains computed while it did are not memoised: they
          # depend on where the walk entered.
          stack = (@stacks[table] ||= [])
          if stack.include?(name) || depth > LIMIT
            @deep ||= depth > LIMIT
            @frames.last&.incomplete = true
            return EMPTY_LIN
          end

          frame = Frame.new(0, false, NO_MARKS, true)
          @frames.push(frame)
          stack.push(name)
          entries, starts, classes = Inference::MemoAudit.key_audit("resolution chain linearisation", &)
          stack.pop
          @frames.pop
          lin = [entries, starts, classes, frame.forks, frame.marks, frame.retro_ok].freeze
          memo[name] = lin unless frame.incomplete
          hand_up(frame)
          lin
        end

        # A memoised linearisation rebuilt for the audit by a Builder over a fresh bucket. A memoised one met no
        # cycle and stayed inside the depth budget, so its depth does not change it; a retro world that fit
        # {LIMIT} once fits it again.
        # A memoised chain's forks are the asker's too.
        def absorb_cached(cached)
          @frames.last&.absorb(cached[3], cached[4], cached[5])
          cached
        end

        def audited_lin(cached, table, name)
          Inference::MemoAudit.check("resolution chain linearisation", cached, table, name) { fresh_lin(table, name) }
        end

        SINGLETON_LIN_TABLES = %i[lin_singleton lin_singleton_retro].freeze
        private_constant :SINGLETON_LIN_TABLES

        def fresh_lin(table, name)
          side = SINGLETON_LIN_TABLES.include?(table) ? :singleton : :instance
          builder = Builder.new(@scope, @flavor, ResolutionChain.send(:flavor_bucket, @discovery, @flavor),
                                retro: @retro)
          Analysis::DependencyRecorder.withhold { builder.send(:lin_for, name, side) }.first
        end

        def hand_up(frame)
          parent = @frames.last
          return if parent.nil?

          parent.absorb(frame.forks, frame.marks, frame.retro_ok)
          parent.incomplete ||= frame.incomplete
        end

        def compute_instance(name, depth)
          twins = same_class_twins(name)
          mark_instance_node(name, :include)
          twins.each { |owner| mark_instance_node(owner, :include) }
          return same_class_instance(name, twins, depth) unless twins.empty?

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
          twins = same_class_twins(name)
          mark_unsettled(name, :extend, (@discovery.discovered_extends[name] || EMPTY).size)
          twins.each { |owner| mark_unsettled(owner, :extend, (@discovery.discovered_extends[owner] || EMPTY).size) }
          return same_class_singleton(name, twins, depth) unless twins.empty?

          entries = [project_entry(name, :singleton)]
          super_lin = superclass_lin(name, :singleton, depth)
          entries.concat(super_lin[0])
          extends = singleton_mixins(name, @discovery.discovered_extends[name] || EMPTY)
          super_start = include_all(entries, name, extends, EMPTY, depth, [0, 1])
          finish(entries, name, super_lin, super_start)
        end

        # #1592 — the class's own `extend`s and the modules its direct mixins' hooks extend it with
        # ({#hook_extensions}), nearest first. Ruby inserts each where its statement ran, and the tables keep the
        # `extend` and `include` statements apart, so with both kinds present the two blocks' order is a fork: the
        # chain puts the own `extend`s nearer (the usual layout writes them after the `include`s) and the retro world
        # the hooks' modules, and a reader that the two worlds answer alike stands, since then only one block can
        # answer the name. An order the hooks do not fix, or an include whose own position is not a fact, is two
        # forks, which settle to master.
        def singleton_mixins(name, extends)
          hooked, open, ordered = hook_extensions(name)
          @frames.last.add_marks(mark_for(name, :include_hook, UNNAMED_LIST, false)) if open
          return extends if hooked.empty?

          fork_hook_order(name, 2) unless ordered
          return hooked if extends.empty?

          fork_hook_order(name, 1)
          @retro ? hooked + extends : extends + hooked
        end

        def fork_hook_order(name, weight)
          @frames.last.forks += weight
          @frames.last.add_marks(mark_for(name, :hook_order, nil, false))
        end

        # `[mixins, open, ordered]` for a class: the `[owner, spelling]` pairs of the modules the hooks of its direct
        # mixins extend it with, nearest first (a later include's ahead of an earlier one's, and within one mixin the
        # hook's own extends ahead of a concern's `ClassMethods`, which `append_features` extends before the
        # `included` block runs); whether one of those hooks may extend it with a module no entry names; and whether
        # the order is a fact. A concern includer gets nothing from a concern: `Concern#append_features` records it
        # as a dependency instead (#2992).
        def hook_extensions(name)
          includes = @discovery.discovered_includes[name] || EMPTY
          return NO_HOOKS if includes.empty?

          listed = @discovery.unpositioned_mixins[name]&.dig(:include) || EMPTY
          hooked = []
          open = false
          ordered = true
          each_hooked_mixin(name, includes) do |raw, mixin, hooks|
            pairs, mixin_open, mixin_ordered = hook_targets(mixin, hooks)
            open ||= mixin_open
            next if pairs.empty?

            ordered &&= mixin_ordered && !listed.include?(raw) && !listed.include?(WILDCARD_LIST.first)
            hooked.concat(pairs)
          end
          # Two files' includes run in load order.
          ordered &&= hooked.size < 2 || !multi_file?(name)
          [hooked.freeze, open, ordered].freeze
        end

        # Yields each direct mixin of `name`, nearest first, as `[spelling, resolved, hooks]`: the hooks its edges
        # run, `:included` for an `include` and `:prepended` for a `prepend`.
        def each_hooked_mixin(name, includes)
          prepends = @discovery.discovered_prepends[name] || EMPTY
          concern = concern?(name)
          includes.uniq.each do |raw|
            mixin = @resolver.resolve_declared(name, raw)
            next if mixin.nil? || (concern && concern?(mixin))

            hooks = []
            hooks << :prepended if prepends.include?(raw)
            hooks << :included if includes.count(raw) > prepends.count(raw)
            yield raw, mixin, hooks
          end
        end

        NO_HOOKS = [EMPTY, false, true].freeze
        private_constant :NO_HOOKS

        def concern?(name)
          bucket = @discovery.discovered_parameter_envelopes[name]
          !bucket.nil? && bucket.key?(CONCERN_KEY)
        end

        CONCERN_KEY = [DiscoveryIndex::ENVELOPE_HOOK_EXTEND_KIND, "ClassMethods", :const_get].freeze
        private_constant :CONCERN_KEY

        # One mixin's hook-extended modules for the edges `hooks` runs, as {#hook_extensions} answers them.
        def hook_targets(mixin, hooks)
          named = []
          const_get = nil
          open = false
          (@discovery.discovered_parameter_envelopes[mixin] || EMPTY_BUCKET).each_key do |key|
            next unless key.is_a?(Array)

            case key.first
            when DiscoveryIndex::ENVELOPE_HOOK_EXTEND_KIND
              if key[2] == :const_get then const_get = key[1]
              elsif hooks.include?(key[2]) then named << key[1]
              end
            when DiscoveryIndex::ENVELOPE_HOOK_EXTEND_OPEN_KIND
              open ||= hooks.include?(key[1])
            end
          end
          pairs = named.uniq.map { |raw| hook_target_pair(mixin, raw) }
          if const_get && (found = const_get_target(mixin, const_get))
            pairs << [mixin, "::#{found}"]
          end
          [pairs, open, named.uniq.size <= 1]
        end

        EMPTY_BUCKET = {}.freeze
        private_constant :EMPTY_BUCKET

        # The module a hook's constant names, written in the mixin's body: `Mixin::Raw` first (the mixin is the
        # innermost cref there), then the names its header's nesting gives. A name no project module answers stays
        # the mixin's spelling, an external entry.
        def hook_target_pair(mixin, raw)
          own = "#{mixin}::#{raw}"
          return [mixin, "::#{own}"] if !raw.start_with?("::") && @resolver.project_name?(own)

          [mixin, raw]
        end

        # `mixin.const_get(raw)`, as `Concern#append_features` looks `ClassMethods` up: `Name::Raw` for each entry of
        # the mixin's own instance chain, then a top-level `Raw`; nil when no project module answers, which Concern
        # then does not extend.
        def const_get_target(mixin, raw)
          chain = ResolutionChain.for(@scope, mixin, :instance, @flavor)
          chain.entries.each do |entry|
            names = entry.external? ? entry.candidates : [entry.name]
            found = names.map { |owner| "#{owner}::#{raw}" }.find { |candidate| @resolver.project_name?(candidate) }
            return found if found
          end
          @resolver.project_name?(raw) ? raw : nil
        end

        # The instance-side marks of one node; `kind` is the side's mixin kind, `:include`. `discovered_includes`
        # already carries the prepended names, so it counts every instance-side edge once.
        def mark_instance_node(name, kind)
          mark_unsettled(name, kind, (@discovery.discovered_includes[name] || EMPTY).size)
          hook = extend_hook_taint(name)
          @frames.last.add_marks(mark_for(name, :extend_hook, hook, false)) if hook
        end

        # Issue #2979 — the names `name`'s envelope bucket binds to the same class object (`K = Struct.new("Named",
        # …)` makes `K` and `Struct::Named` one class), without `name`; empty, and allocating nothing, for nearly every
        # class. The chain of either name heads with every name's entry, so a reader asks each name's own tables where
        # Ruby asks the one class's; nothing is copied between the names. Only the direct binding counts: two
        # `Struct.new("Named", …)` writes make two classes in Ruby, and neither constant reaches the other's tables
        # through `Struct::Named`. {ResolutionChain#ancestors_start} tells a reader where the true ancestors begin.
        def same_class_twins(name)
          twins = DiscoveryIndex.same_class_names(@discovery.discovered_parameter_envelopes[name])
          twins.include?(name) ? twins - [name] : twins
        end

        # The instance side of a class with twins: every name's prepends ahead of the class, then every name's
        # includes after the LAST name, so the names stay ahead of every module either one includes, as the one class
        # heads its own ancestors. The superclass edge stays `name`'s own: a Struct's class has none the tables
        # record, under either name.
        def same_class_instance(name, twins, depth)
          names = [name, *twins].uniq
          entries = names.map { |owner| project_entry(owner, :instance) }
          super_lin = superclass_lin(name, :instance, depth)
          entries.concat(super_lin[0])
          boundary = [0, names.size]
          names.each do |owner|
            boundary = prepend_all(entries, owner, @discovery.discovered_prepends[owner] || EMPTY, depth, boundary)
          end
          super_start = names.reduce(boundary[1]) do |start, owner|
            include_all(entries, owner, @discovery.discovered_includes[owner] || EMPTY,
                        @discovery.discovered_prepends[owner] || EMPTY, depth, [boundary[0] + names.size - 1, start])
          end
          finish(entries, name, super_lin, super_start)
        end

        # The singleton twin of {#same_class_instance}: every name's class-object entry, then every name's extends.
        def same_class_singleton(name, twins, depth)
          names = [name, *twins].uniq
          entries = names.map { |owner| project_entry(owner, :singleton) }
          super_lin = superclass_lin(name, :singleton, depth)
          entries.concat(super_lin[0])
          super_start = names.reduce(names.size) do |start, owner|
            include_all(entries, owner, @discovery.discovered_extends[owner] || EMPTY, EMPTY, depth,
                        [names.size - 1, start])
          end
          finish(entries, name, super_lin, super_start)
        end

        # Marks the node being computed unsettled when the order of its mixin edges on `kind` is not a fact
        # (`DiscoveryIndex#unpositioned_mixins`: an edge written in a conditional, a method, a block or a hook,
        # or a call the walk cannot record, `"*"`), or when its class is declared in more than one file and
        # has two or more such edges, whose order across the files is load order. A node's mark taints every
        # chain that draws on it, so a concern's `included do` edges taint every includer. The {Mark} says why,
        # which is what per-name relevance reads.
        def mark_unsettled(name, kind, edge_count)
          listed = @discovery.unpositioned_mixins[name]&.dig(kind)
          listed = nil if listed && listed.empty?
          multi = edge_count >= 2 && multi_file?(name)
          return if listed.nil? && !multi

          @frames.last.add_marks(mark_for(name, kind, listed, multi))
        end

        # The one-element frozen array carrying the {Mark} of `[name, kind]`, interned in the bucket.
        def mark_for(name, kind, listed, multi)
          by_node = (@bucket[:marks][kind] ||= {})
          cached = by_node[name]
          if cached.nil?
            return by_node[name] = Inference::MemoAudit.key_audit("resolution chain mark") do
              new_mark(name, kind, listed, multi)
            end
          end
          return cached unless Inference::MemoAudit.enabled?

          # The failure names the whole key: the bucket's flavor, the mark's kind, the node.
          Inference::MemoAudit.check("resolution chain mark", cached, [@flavor, kind], name) do
            new_mark(name, kind, listed, multi)
          end
        end

        def new_mark(name, kind, listed, multi)
          [ResolutionChain::Mark.new(name, kind, listed.nil? ? EMPTY : listed.to_a.freeze, multi)].freeze
        end

        # The `[origin, super_start]` of a one-name chain: the class at 0, its superclass's entries from 1.
        CLASS_FIRST = [0, 1].freeze
        private_constant :CLASS_FIRST

        # #1730 — whether a module `name` extends has a hook that may mix into `name`'s instance side or its
        # includers' ({ResolutionChain.extend_reshapes_instance?}). Ruby runs it at the `extend`, so the mixin is
        # not a fact of the tables and `name`'s instance side is unpositioned. A spelling no project module
        # answers taints nothing: the project cannot see its hooks.
        #
        # The mark's list: nil when no extended module taints, else {UNNAMED_LIST} when one of those modules lists `"?"`
        # (#2991), {WILDCARD_LIST} otherwise. Only the marker carries over: a name such a module lists is spelled
        # relative to that module, not to the extender.
        def extend_hook_taint(name)
          found = nil
          (@discovery.discovered_extends[name] || EMPTY).each do |raw|
            resolved = @resolver.resolve_one(name, raw)
            next if resolved.nil? || !ResolutionChain.extend_reshapes_instance?(@scope, resolved)
            return UNNAMED_LIST if @discovery.unpositioned_mixins[resolved][:include].include?(UNNAMED_LIST.last)

            found = WILDCARD_LIST
          end
          found
        end

        WILDCARD_LIST = ["*"].freeze # Relevance::WILDCARD, which loads after this file
        UNNAMED_LIST = ["*", "?"].freeze # with Relevance::UNNAMED
        private_constant :WILDCARD_LIST, :UNNAMED_LIST

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
            [[external_entry(name, raw, side, true)].freeze, [0].freeze, [nil].freeze, 0, NO_MARKS, true].freeze
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
        def prepend_all(entries, owner, prepends, depth, boundary = CLASS_FIRST)
          origin, super_start = boundary
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

            # A hook's module comes as `[owner, spelling]`: the mixin whose body wrote it resolves it.
            from, raw = raw.is_a?(Array) ? raw : [owner, raw]
            each_mixin_chain(from, raw, depth) do |sub|
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
          cached = by_side[name]
          if cached.nil?
            return by_side[name] = Inference::MemoAudit.key_audit("resolution chain entry") do
              new_project_entry(name, side)
            end
          end
          return cached unless Inference::MemoAudit.enabled?

          Inference::MemoAudit.check("resolution chain entry", cached, [@flavor, side], name) do
            new_project_entry(name, side)
          end
        end

        def new_project_entry(name, side)
          Entry.new(name, side, nil, nil, false, name.to_s.split("::").last.freeze, nil)
        end

        def external_entry(owner, raw, side, superclass_edge)
          by_edge = ((@bucket[:externals][side] ||= {})[superclass_edge] ||= {})
          by_owner = (by_edge[owner] ||= {})
          cached = by_owner[raw]
          if cached.nil?
            return by_owner[raw] = Inference::MemoAudit.key_audit("resolution chain external entry") do
              new_external_entry(owner, raw, side, superclass_edge)
            end
          end
          return cached unless Inference::MemoAudit.enabled?

          # The failure names the whole key: flavor, side, superclass edge, owner and spelling.
          Inference::MemoAudit.check("resolution chain external entry", cached, [@flavor, side, superclass_edge],
                                     [owner, raw]) do
            Analysis::DependencyRecorder.withhold { new_external_entry(owner, raw, side, superclass_edge) }.first
          end
        end

        def new_external_entry(owner, raw, side, superclass_edge)
          Entry.new(nil, side, raw, @scope.ancestor_name_candidates(owner, raw).freeze, superclass_edge, nil, owner)
        end
      end
      private_constant :Builder
    end
  end
end

require_relative "resolution_chain/relevance"
