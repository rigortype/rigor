# frozen_string_literal: true

require_relative "../typing_state"

module Rigor
  module Analysis
    # ADR-46 slice 1 — records, per analyzed file, which OTHER source files its analysis read declarations /
    # method bodies from (the cross-file dependency edges), plus the cross-file lookups that resolved to
    # nothing (negative edges — adding that symbol later must re-check the consumer).
    #
    # Thread-local and activated per `analyze_file` only when the runner opts in (`record_dependencies: true`);
    # a normal run never activates it, so {active?} is a single nil-check and the instrumented `Scope`
    # accessors pay nothing. Recording is purely observational — it never changes a diagnostic.
    #
    # Modelled on {Inference::BudgetTrace}: process-thread-local state, a cheap disabled fast path, and a
    # frozen snapshot for consumers.
    module DependencyRecorder # rubocop:disable Metrics/ModuleLength
      # ADR-129 WD1 — the installed accumulator is a Frame whose contents are a Resource for its suspension count, the
      # one mutation that touches ({record_for}); its filings are entries of the bound Table {READS} and are journaled
      # instead. The `type_of` memo stays shut while recording runs (WD4). The activation count below is a process
      # switch, outside the typing state (WD5).
      RECORDER = TypingState.frame(
        :dependency_recorder,
        contents: :resource, reason: "the consumer's accumulator a recording installs; each read files into it"
      )
      private_constant :RECORDER

      # ADR-129 WD1 — the recorded dependency reads are a bound Table: the installed {Accumulator} and each open
      # {Capture} are its stores, keyed on the event tuples they deduplicate on (a frozen `[path, symbol_or_nil]` pair
      # for a positive edge, a `"kind:name"` String for a name-keyed one). Each event that files into a store logs a
      # read of its key (`true` when the store already held it, else {TypingState::ABSENT}) and, when it adds, a write
      # of `true`, while a capture is open, so a later `type_of` memo can validate the reads and replay the writes.
      # The keys are built only then: a run with no journal capture open allocates nothing for the journal, whether
      # or not an ADR-84 capture is open.
      READS = TypingState.table(
        :dependency_reads,
        bound: true,
        reason: "event tuple => true per accumulator and per open capture; set-only, in first-filing order"
      )
      private_constant :READS

      # ADR-84 WD2 — thread-local Array of active {Capture}s (nil when none). A capture observes-and-forwards:
      # every read recorded while it is active flows into the current consumer's accumulator exactly as before
      # AND into every active capture, so a caller gets a replayable read-set without disturbing recording.
      # It is a STACK because captures nest (a memoised callee body evaluating another memo-miss callee): an
      # outer capture must also see the inner window's reads, or its read-set would be non-transitive and a
      # later replay would drop the nested callee's edges.
      #
      # Every event reaches every capture open at the time, so an inner capture's sets are always a subset of
      # each outer one's: the inner capture was pushed after the outer, and everything added since reached both.
      # {withhold} swaps in a fresh stack and restores this one untouched, so it keeps the property too.
      # {tee_read} and {tee_missing} rely on it to stop at the first capture that already holds an event.
      #
      # ADR-129 WD3 — the stack is an id-determined Resource: every change of it ({capture}'s push and pop,
      # {withhold}'s swap and restore) takes a fresh state id, so reading it on the event paths is exempt.
      CAPTURES = TypingState.resource(
        :dependency_capture_stack,
        read_exemption: :id_determined,
        reason: "the open capture windows, pushed per window and swapped by withhold"
      )
      private_constant :CAPTURES

      # The read sets an {Accumulator} or {Capture} already holds in full, by identity: replayed into it, or
      # captured by a window it saw every event of ({capture}). Both only ever grow and a {ReadSet} is frozen,
      # so replaying such a set into the same target again adds nothing. Recording replays the same stored
      # read set many times over: on Rigor's own `lib`, 71% of the replays into a consumer repeated one
      # already made into it, carrying 65% of the replayed events.
      #
      # ADR-129 — the held marks are an extensional dedupe cache over the store's own {READS} entries (every event of
      # a held set is already in the store), so marking and probing them log nothing; {ChainMemory} likewise.
      module ReplayMemory
        def holds?(read_set)
          !@held.nil? && @held.key?(read_set)
        end

        # Called only once every event of `read_set` is in, so a replay that raises part-way leaves the
        # target unmarked and the next replay adds the rest.
        def hold!(read_set)
          (@held ||= {}.compare_by_identity)[read_set] = true
        end
      end

      # #1590 — the resolution-chain filings ({file_chain_once}) an {Accumulator} or {Capture} already holds in
      # full: per chain (by identity; the table holds the chain, so its identity cannot be reused while the target
      # lives), the starts filed from it and the discovery index each was filed against. A filing is a pure
      # function of those three, so filing it again into the same target adds nothing.
      module ChainMemory
        def chain_filed?(chain, start, discovery)
          table = @chains&.[](chain)
          !table.nil? && table.key?(start) && table[start].equal?(discovery)
        end

        def chain_filed!(chain, start, discovery)
          ((@chains ||= {}.compare_by_identity)[chain] ||= {})[start] = discovery
        end
      end

      # Mutable per-consumer accumulator. Frozen into a {Record} snapshot when `record_for` returns.
      class Accumulator
        include ReplayMemory
        include ChainMemory

        attr_reader :consumer, :sources, :missing, :symbol_sources, :ancestry_sources, :suspensions

        def initialize(consumer)
          @consumer = consumer
          @sources = Set.new
          @missing = Set.new
          # ADR-46 slice 4 — symbol-granularity tracking.
          # `symbol_sources`: source_path → the "ClassName#method" names read from it, for method-call deps.
          # `ancestry_sources`: the source paths read for class-ancestry (superclass / include) deps —
          # file-granularity by nature (a superclass edge touches the whole class).
          @symbol_sources = Hash.new { |h, k| h[k] = Set.new }
          @ancestry_sources = Set.new
          @held = nil
          @chains = nil
          @suspensions = 0
        end

        # Counts the {record_for} windows of another consumer opened while this one was recording, which is
        # when a capture window stops seeing only this consumer's events.
        def suspend!
          @suspensions += 1
        end

        def snapshot
          frozen_sym = @symbol_sources.transform_values(&:freeze).freeze
          Record.new(
            consumer: consumer,
            sources: sources.dup.freeze,
            missing: missing.dup.freeze,
            symbol_sources: frozen_sym,
            ancestry_sources: ancestry_sources.dup.freeze
          )
        end
      end

      # Frozen record of one file's cross-file reads.
      # `symbol_sources`: source_path → frozen set of "ClassName#method" names (method-call edges).
      # `ancestry_sources`: frozen set of source paths (class-ancestry edges, file-granularity).
      Record = Data.define(:consumer, :sources, :missing, :symbol_sources, :ancestry_sources)

      # ADR-84 WD2 — a replayable, consumer-independent read-set: `reads` is a frozen Set of frozen
      # `[path, symbol_or_nil]` pairs (symbol nil = ancestry edge), `missing` a frozen Set of `"kind:name"`
      # strings. Deliberately UNFILTERED by consumer: a read of the capturing consumer's own file is included
      # because it is a genuine cross-file edge for every OTHER consumer a replay may serve — the per-consumer
      # self-read filter is applied at {replay} time, mirroring {read_site}.
      ReadSet = Data.define(:reads, :missing)

      # What every window that saw nothing closes into: most windows {RbsDispatch}'s recording-mode memos
      # open see nothing, and they need neither a copy of two empty Sets nor a place in a target's
      # {ReplayMemory}.
      EMPTY_READ_SET = Ractor.make_shareable(ReadSet.new(reads: Set.new, missing: Set.new))

      # Mutable capture accumulator; snapshot into a frozen {ReadSet} when the capture window closes.
      class Capture
        include ReplayMemory
        include ChainMemory

        attr_reader :reads, :missing

        def initialize
          @reads = Set.new
          @missing = Set.new
          @held = nil
          @chains = nil
        end

        def snapshot
          return EMPTY_READ_SET if reads.empty? && missing.empty?

          ReadSet.new(reads: reads.dup.freeze, missing: missing.dup.freeze)
        end
      end

      # Module-level activation count so the disabled fast path ({active?}) is a plain integer read rather
      # than a `Thread.current` hash lookup — `user_def_for` (the instrumented accessor) is on the
      # per-dispatch hot path, so a normal (non-recording) run must pay as little as possible. The per-thread
      # accumulator still isolates the actual recording, so a non-recording thread seeing `active?` true
      # (another thread is recording) just performs an extra nil-check.
      @active_count = 0
      @mutex = Mutex.new

      module_function

      # Activates recording for `consumer` (the path being analyzed) for the duration of the block and returns
      # the frozen {Record}. Nests safely (the inner consumer's reads do not leak to the outer one); restores
      # the previous recorder on exit.
      def record_for(consumer)
        state = TypingState.current
        previous = state[RECORDER]
        if previous
          state.touch(RECORDER)
          previous.suspend!
        end
        accumulator = Accumulator.new(consumer.to_s)
        state.with(RECORDER, accumulator) do
          @mutex.synchronize { @active_count += 1 }
          begin
            yield
            accumulator.snapshot
          ensure
            @mutex.synchronize { @active_count -= 1 }
          end
        end
      end

      # Plain integer read (GVL-atomic) — no `Thread.current` lookup on the disabled fast path.
      def active?
        @active_count.positive?
      end

      # Whether THIS thread's reads reach an accumulator: inside {record_for}, including a {withhold}
      # window. {active?} answers for the process and is the cheap gate; this is the exact one, for a caller
      # that must know whether an empty {capture} means "nothing to record" or "nothing was watching".
      def recording?
        !TypingState.current[RECORDER].nil?
      end

      # ADR-84 WD2 — runs the block under an observe-and-forward capture window and returns
      # `[block_result, read_set]`. Reads recorded during the window reach the current consumer's accumulator
      # unchanged (forwarding) and are additionally collected into the returned frozen {ReadSet} (observing),
      # which {replay} can later apply to a different consumer. Nests (see CAPTURES). Callers guard on
      # {active?}; opening a capture with no accumulator active would collect reads no run is recording.
      def capture
        state = TypingState.current
        accumulator = state[RECORDER]
        suspensions = accumulator&.suspensions
        capture = Capture.new
        state.push(CAPTURES, capture)
        begin
          result = yield
        ensure
          state.pop(CAPTURES)
        end
        captures = state[CAPTURES]
        read_set = capture.snapshot
        note_captured(read_set, captures, accumulator, suspensions)
        [result, read_set]
      end

      # Every event a window saw also reached the window outside it, and was filed for the consumer that was
      # recording at the time, except the consumer's own self-reads, which a replay into that consumer drops
      # anyway. So the enclosing window holds the closed window's read set in full, and so does the consumer's
      # accumulator when no other consumer recorded in between. Noting that lets a later replay of the set
      # there skip a pass that could add nothing: on Rigor's own `lib`, two thirds of the first replays into a
      # consumer were of a set captured while that consumer was recording.
      def note_captured(read_set, captures, accumulator, suspensions)
        return if read_set.equal?(EMPTY_READ_SET)

        captures.last&.hold!(read_set)
        return unless accumulator && TypingState.current[RECORDER].equal?(accumulator)
        return unless accumulator.suspensions == suspensions

        accumulator.hold!(read_set)
      end
      private_class_method :note_captured

      # Issue #992 — runs the block with its reads DETACHED from the current consumer (and from any enclosing
      # capture) and returns `[block_result, read_set]`, so a caller that learns only afterwards whether its
      # answer depended on those reads can {replay} them or drop them. `call.wrong-arity` reads a class's whole
      # envelope bucket to decide a call that turns out to fit, and recording that as a file-level ancestry
      # edge would make every correct call on a project class re-check on any edit to the class's files.
      # Returns a nil read set when no recording is active.
      def withhold
        state = TypingState.current
        previous = state[RECORDER]
        return [yield, nil] if previous.nil?

        previous_captures = state[CAPTURES]
        capture = Capture.new
        result = state.with(RECORDER, Accumulator.new(previous.consumer)) do
          # A swap of the whole stack: a write, then a rewrite, so the swapped-in stack is read under a fresh id.
          state.write(CAPTURES, [capture])
          state.rewrite(CAPTURES)
          begin
            yield
          ensure
            state.write(CAPTURES, previous_captures)
            state.rewrite(CAPTURES)
          end
        end
        [result, capture.snapshot]
      end

      # ADR-84 WD2 — replays a {ReadSet} into the current consumer's accumulator as if each read happened
      # here, applying the same per-consumer self-read filter as {read_site}, and tees into every active
      # capture so an enclosing capture window stays transitive when a memo hit substitutes for a body walk.
      def replay(read_set)
        state = TypingState.current
        accumulator = state[RECORDER]
        return if accumulator.nil? || read_set.nil? || read_set.equal?(EMPTY_READ_SET)

        captures = state[CAPTURES]
        tee_read_set(state, captures, read_set) if captures && !captures.empty?
        # Each set keeps its own insertion order whichever target is filled first, and a skipped replay is one
        # that could only have re-added what the target already holds.
        return if accumulator.holds?(read_set)

        consumer = accumulator.consumer
        read_set.reads.each do |pair|
          path, symbol = pair
          next if path == consumer

          added = accumulate_read(accumulator, path, symbol)
          log_filing(state, accumulator, pair, added) if state.capturing?
        end
        missing = accumulator.missing
        read_set.missing.each { |entry| file_missing(state, accumulator, missing, entry) }
        accumulator.hold!(read_set)
      end

      # #1590 — runs the block, which files a resolution chain's edges from entry `start` (nil: the root and the
      # whole chain) against `discovery`, unless the current consumer's accumulator AND the innermost open capture
      # already hold that filing; the block files the same edges every time, so skipping it there changes nothing.
      # Every event reaches every capture open at the time (see CAPTURES), so the innermost capture holding the
      # filing means every open capture does. A filing the accumulator holds but a capture opened since does not is
      # filed again, so that capture's read set, replayed elsewhere, still carries it; and {withhold} starts a fresh
      # accumulator and capture, which hold nothing. The marks are made only once the block has run, as {hold!}'s are.
      def file_chain_once(chain, start, discovery)
        state = TypingState.current
        accumulator = state[RECORDER]
        return if accumulator.nil?

        captures = state[CAPTURES]
        open = captures && !captures.empty?
        if accumulator.chain_filed?(chain, start, discovery) &&
           (!open || captures.last.chain_filed?(chain, start, discovery))
          return
        end

        yield
        accumulator.chain_filed!(chain, start, discovery)
        captures.each { |capture| capture.chain_filed!(chain, start, discovery) } if open
      end

      # {replay}'s share for the open captures. The innermost capture having seen `read_set` already means every
      # open capture holds all of it (see CAPTURES).
      def tee_read_set(state, captures, read_set)
        innermost = captures.last
        return if innermost.holds?(read_set)

        read_set.reads.each { |pair| tee_read(state, captures, pair) }
        read_set.missing.each { |entry| tee_missing(state, captures, entry) }
        innermost.hold!(read_set)
      end
      private_class_method :tee_read_set

      # Adds a read pair to the open captures, innermost first, and stops at the first capture that already holds
      # it: every capture outside that one holds it too (see CAPTURES). The capture sets end up exactly as
      # adding it to every capture would leave them, in the same insertion order. Each capture probed logs its
      # filing; the ones outside the first holder are not probed, and hold the key by the same property.
      def tee_read(state, captures, pair)
        if state.capturing?
          tee_logged(state, captures, pair, :reads)
        else
          index = captures.size - 1
          index -= 1 while index >= 0 && captures[index].reads.add?(pair)
        end
      end
      private_class_method :tee_read

      # {tee_read} for a name-keyed `missing` entry.
      def tee_missing(state, captures, entry)
        if state.capturing?
          tee_logged(state, captures, entry, :missing)
        else
          index = captures.size - 1
          index -= 1 while index >= 0 && captures[index].missing.add?(entry)
        end
      end
      private_class_method :tee_missing

      # {tee_read} / {tee_missing} while a capture is open: the same walk, logging each capture's filing.
      def tee_logged(state, captures, key, set)
        index = captures.size - 1
        while index >= 0
          capture = captures[index]
          added = capture.public_send(set).add?(key)
          log_filing(state, capture, key, added)
          break unless added

          index -= 1
        end
      end
      private_class_method :tee_logged

      # Logs one filing of `key` into `store` (an {Accumulator} or a {Capture}): a read of the key, which the store held
      # unless the filing `added` it, and the write when it did. Callers log only while a capture is open.
      def log_filing(state, store, key, added)
        state.log_bound_read(READS, store, key, added ? TypingState::ABSENT : true)
        state.log_bound_write(READS, store, key, true) if added
      end
      private_class_method :log_filing

      # Files a name-keyed entry into an accumulator's `missing` set, logging the filing while a capture is open.
      def file_missing(state, accumulator, missing, entry)
        if state.capturing?
          log_filing(state, accumulator, entry, missing.add?(entry))
        else
          missing << entry
        end
      end
      private_class_method :file_missing

      # Records that the current consumer read a declaration / body whose definition site is `path_line` (a
      # `"path:line"` String, or nil). When `symbol` is given (a `"ClassName#method"` String), the read is a
      # method-call edge and is recorded at symbol granularity in `symbol_sources` in addition to the coarse
      # `sources` set. Without `symbol` the read is a class-ancestry edge (file-granularity) and is added to
      # `ancestry_sources` only. Self-reads and nil sites are ignored for the accumulator; active captures
      # (ADR-84 WD2) observe every valid-path read UNfiltered — the self-read filter is per-consumer and is
      # re-applied by {replay} against whichever consumer a replay serves.
      def read_site(path_line, symbol = nil)
        state = TypingState.current
        accumulator = state[RECORDER]
        return if accumulator.nil? || path_line.nil?

        path = site_path(path_line)
        return unless path

        captures = state[CAPTURES]
        pair = [path, symbol].freeze if (captures && !captures.empty?) || state.capturing?
        tee_read(state, captures, pair) if captures && !captures.empty?
        return if path == accumulator.consumer

        added = accumulate_read(accumulator, path, symbol)
        log_filing(state, accumulator, pair, added) if state.capturing?
      end

      # The path part of a `"path:line"` site: what `path_line.split(":", 2).first` answers, without the Array
      # and the discarded line String.
      def site_path(path_line)
        colon = path_line.byteindex(":")
        return path_line.byteslice(0, colon) if colon

        path_line.empty? ? nil : path_line.dup
      end
      private_class_method :site_path

      # Records a NAME-KEYED cross-file dependency: this consumer's answer depends on what the project makes
      # of `name` under `kind`, so a recheck must re-analyze it when that changes. The recorded key is
      # inverted into `negative_dependents` and matched against the producer for its kind.
      #
      # For `:method` / `:class` / `:toplevel` this is recorded only on a MISS ({read_missing}) — a resolved
      # method or class already carries a positive edge to its definition site, which covers every later
      # change to it. Issue #644's `:constant` kind is recorded on a HIT as well, because a constant's
      # published value is a function of the WHOLE project's write set for the name, not of the one file that
      # currently wins: a second declarer appearing in a file the reader has no edge to must drop the name to
      # `Dynamic` at that reader, and only a name-keyed edge can see it.
      def read_name(kind, name)
        state = TypingState.current
        accumulator = state[RECORDER]
        return if accumulator.nil?

        entry = "#{kind}:#{name}"
        captures = state[CAPTURES]
        tee_missing(state, captures, entry) if captures && !captures.empty?
        file_missing(state, accumulator, accumulator.missing, entry)
      end

      # {read_name} keyed on the LAST SEGMENT of a constant path, `name.delete_prefix("::").split("::").last`,
      # which is the key the `class:` and `constant:` name edges use. The segment is found by scanning for the
      # last separator rather than by building every segment: on Rigor's own `lib` that split cost about seven
      # objects a call over half a million calls. A name the scan could read differently from `split` (one
      # that is not ASCII, or carries a run of colons or a trailing one) takes `split`'s answer.
      def read_last_segment(kind, name)
        return unless recording?

        segment = last_segment(name)
        read_name(kind, segment) if segment
      end

      def last_segment(name)
        return name.delete_prefix("::").split("::").last unless plain_constant_path?(name)

        start = name.start_with?("::") ? 2 : 0
        separator = name.rindex("::")
        cut = separator && separator >= start ? separator + 2 : start
        cut == name.bytesize ? nil : name.byteslice(cut, name.bytesize - cut)
      end
      private_class_method :last_segment

      def plain_constant_path?(name)
        name.ascii_only? && !name.end_with?(":") && !name.include?(":::")
      end
      private_class_method :plain_constant_path?

      # {read_name} for prebuilt, frozen `"kind:name"` keys: a caller that files the same keys on every read
      # (a resolution chain's hook edges, #1641) builds them once and adds them here without a String apiece.
      def read_keys(keys)
        state = TypingState.current
        accumulator = state[RECORDER]
        return if accumulator.nil?

        captures = state[CAPTURES]
        open = captures && !captures.empty?
        missing = accumulator.missing
        keys.each do |entry|
          tee_missing(state, captures, entry) if open
          file_missing(state, accumulator, missing, entry)
        end
      end

      # Issue #2134 — {read_name} for a read of `class_name`'s visibility slots for `method_name`, on either side, or
      # of their contest: `visibility:<class>#<method>`. `IncrementalSession#visibility_name_affected` fires the key
      # when a file's visibility entry or contest for the slot moves. A reader that asks whether ANY class records
      # the name private passes `"*"` as the class; the key fires when any entry of the name moves. A wildcard
      # slot (`[:singleton, :*]`) is `*` as the method name.
      def read_visibility(class_name, method_name)
        return unless recording?

        read_name(:visibility, "#{class_name}##{method_name}")
      end

      # The miss-only spelling of {read_name}: a cross-file lookup of `name` (kind `:method` / `:class` /
      # `:toplevel` / …) that resolved to nothing. Kept as the name the internal spec's negative-edge
      # contract uses.
      def read_missing(kind, name)
        read_name(kind, name)
      end

      # The positive-edge aggregation shared by {read_site} and {replay}. `sources` is the union of the other
      # two tables' paths, and this is the only writer of all three, so a read the finer table already holds is
      # already in `sources` and costs one Set probe instead of two. Answers whether the read was new to the
      # accumulator (truthy) or already held (nil), which is its {READS} filing.
      def accumulate_read(accumulator, path, symbol)
        added = symbol ? accumulator.symbol_sources[path].add?(symbol) : accumulator.ancestry_sources.add?(path)
        accumulator.sources << path if added
        added
      end
      private_class_method :accumulate_read
    end
  end
end
