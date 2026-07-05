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

      # Records that the current consumer read a declaration / body whose definition site is `path_line` (a
      # `"path:line"` String, or nil). When `symbol` is given (a `"ClassName#method"` String), the read is a
      # method-call edge and is recorded at symbol granularity in `symbol_sources` in addition to the coarse
      # `sources` set. Without `symbol` the read is a class-ancestry edge (file-granularity) and is added to
      # `ancestry_sources` only. Self-reads and nil sites are ignored in all cases.
      def read_site(path_line, symbol = nil)
        accumulator = Thread.current[KEY]
        return if accumulator.nil? || path_line.nil?

        path = path_line.split(":", 2).first
        return unless path && path != accumulator.consumer

        accumulator.sources << path
        if symbol
          accumulator.symbol_sources[path] << symbol
        else
          accumulator.ancestry_sources << path
        end
      end

      # Records a cross-file lookup of `name` (kind `:method` / `:class` / `:const` / …) that resolved to
      # nothing — a negative dependency.
      def read_missing(kind, name)
        accumulator = Thread.current[KEY]
        accumulator&.missing&.add("#{kind}:#{name}")
      end
    end
  end
end
