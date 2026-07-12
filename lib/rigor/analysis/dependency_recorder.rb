# frozen_string_literal: true

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
    module DependencyRecorder
      KEY = :__rigor_dependency_recorder__
      private_constant :KEY

      # ADR-84 WD2 — thread-local Array of active {Capture}s (nil when none). A capture observes-and-forwards:
      # every read recorded while it is active flows into the current consumer's accumulator exactly as before
      # AND into every active capture, so a caller gets a replayable read-set without disturbing recording.
      # It is a STACK because captures nest (a memoised callee body evaluating another memo-miss callee): an
      # outer capture must also see the inner window's reads, or its read-set would be non-transitive and a
      # later replay would drop the nested callee's edges.
      CAPTURE_KEY = :__rigor_dependency_capture_stack__
      private_constant :CAPTURE_KEY

      # Mutable per-consumer accumulator. Frozen into a {Record} snapshot when `record_for` returns.
      class Accumulator
        attr_reader :consumer, :sources, :missing, :symbol_sources, :ancestry_sources

        def initialize(consumer)
          @consumer = consumer
          @sources = Set.new
          @missing = Set.new
          # ADR-46 slice 4 — symbol-granularity tracking.
          # `symbol_sources`: source_path → Set<"ClassName#method"> for method-call deps.
          # `ancestry_sources`: Set<source_path> for class-ancestry (superclass / include) deps —
          # file-granularity by nature (a superclass edge touches the whole class).
          @symbol_sources = Hash.new { |h, k| h[k] = Set.new }
          @ancestry_sources = Set.new
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
      # `symbol_sources`: source_path → frozen Set<"ClassName#method"> (method-call edges).
      # `ancestry_sources`: frozen Set<source_path> (class-ancestry edges, file-granularity).
      Record = Data.define(:consumer, :sources, :missing, :symbol_sources, :ancestry_sources)

      # ADR-84 WD2 — a replayable, consumer-independent read-set: `reads` is a frozen Set of frozen
      # `[path, symbol_or_nil]` pairs (symbol nil = ancestry edge), `missing` a frozen Set of `"kind:name"`
      # strings. Deliberately UNFILTERED by consumer: a read of the capturing consumer's own file is included
      # because it is a genuine cross-file edge for every OTHER consumer a replay may serve — the per-consumer
      # self-read filter is applied at {replay} time, mirroring {read_site}.
      ReadSet = Data.define(:reads, :missing)

      # Mutable capture accumulator; snapshot into a frozen {ReadSet} when the capture window closes.
      class Capture
        attr_reader :reads, :missing

        def initialize
          @reads = Set.new
          @missing = Set.new
        end

        def snapshot
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
        previous = Thread.current[KEY]
        accumulator = Accumulator.new(consumer.to_s)
        Thread.current[KEY] = accumulator
        @mutex.synchronize { @active_count += 1 }
        yield
        accumulator.snapshot
      ensure
        Thread.current[KEY] = previous
        @mutex.synchronize { @active_count -= 1 }
      end

      # Plain integer read (GVL-atomic) — no `Thread.current` lookup on the disabled fast path.
      def active?
        @active_count.positive?
      end

      # ADR-84 WD2 — runs the block under an observe-and-forward capture window and returns
      # `[block_result, read_set]`. Reads recorded during the window reach the current consumer's accumulator
      # unchanged (forwarding) and are additionally collected into the returned frozen {ReadSet} (observing),
      # which {replay} can later apply to a different consumer. Nests (see CAPTURE_KEY). Callers guard on
      # {active?}; opening a capture with no accumulator active would collect reads no run is recording.
      def capture
        captures = (Thread.current[CAPTURE_KEY] ||= [])
        capture = Capture.new
        captures.push(capture)
        begin
          result = yield
        ensure
          captures.pop
        end
        [result, capture.snapshot]
      end

      # ADR-84 WD2 — replays a {ReadSet} into the current consumer's accumulator as if each read happened
      # here, applying the same per-consumer self-read filter as {read_site}, and tees into every active
      # capture so an enclosing capture window stays transitive when a memo hit substitutes for a body walk.
      def replay(read_set)
        accumulator = Thread.current[KEY]
        return if accumulator.nil? || read_set.nil?

        captures = Thread.current[CAPTURE_KEY]
        read_set.reads.each do |pair|
          captures&.each { |c| c.reads.add(pair) }
          path, symbol = pair
          next if path == accumulator.consumer

          accumulate_read(accumulator, path, symbol)
        end
        read_set.missing.each do |entry|
          captures&.each { |c| c.missing.add(entry) }
          accumulator.missing << entry
        end
      end

      # Records that the current consumer read a declaration / body whose definition site is `path_line` (a
      # `"path:line"` String, or nil). When `symbol` is given (a `"ClassName#method"` String), the read is a
      # method-call edge and is recorded at symbol granularity in `symbol_sources` in addition to the coarse
      # `sources` set. Without `symbol` the read is a class-ancestry edge (file-granularity) and is added to
      # `ancestry_sources` only. Self-reads and nil sites are ignored for the accumulator; active captures
      # (ADR-84 WD2) observe every valid-path read UNfiltered — the self-read filter is per-consumer and is
      # re-applied by {replay} against whichever consumer a replay serves.
      def read_site(path_line, symbol = nil)
        accumulator = Thread.current[KEY]
        return if accumulator.nil? || path_line.nil?

        path = path_line.split(":", 2).first
        return unless path

        captures = Thread.current[CAPTURE_KEY]
        captures&.each { |c| c.reads.add([path, symbol].freeze) }
        return if path == accumulator.consumer

        accumulate_read(accumulator, path, symbol)
      end

      # Records a cross-file lookup of `name` (kind `:method` / `:class` / `:const` / …) that resolved to
      # nothing — a negative dependency.
      def read_missing(kind, name)
        accumulator = Thread.current[KEY]
        return if accumulator.nil?

        entry = "#{kind}:#{name}"
        Thread.current[CAPTURE_KEY]&.each { |c| c.missing.add(entry) }
        accumulator.missing.add(entry)
      end

      # The positive-edge aggregation shared by {read_site} and {replay}.
      def accumulate_read(accumulator, path, symbol)
        accumulator.sources << path
        if symbol
          accumulator.symbol_sources[path] << symbol
        else
          accumulator.ancestry_sources << path
        end
      end
      private_class_method :accumulate_read
    end
  end
end
