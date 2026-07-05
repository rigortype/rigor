# frozen_string_literal: true

module Rigor
  module Inference
    # Thread-local event recorder behind `rigor trace`: while a block runs under {record}, the inference engine
    # emits a flat, ordered event stream describing HOW it typed the program — expression enter/result pairs, scope
    # binds, union formation, and method-dispatch outcomes. The CLI replays that stream as a terminal animation (or
    # dumps it as JSON); the engine itself never reads the events back, so recording is purely observational and
    # MUST NOT change any inferred type.
    #
    # Modelled on {Analysis::DependencyRecorder}: thread-local state, a module-level activation count so the
    # disabled fast path ({active?}) is a plain integer read, and a frozen snapshot for consumers. The instrumented
    # hot paths (`ExpressionTyper#type_of`, `Scope#with_local`, `Type::Combinator.union`, `MethodDispatcher.dispatch`)
    # each guard their emit behind {active?}, so a normal (non-tracing) run pays one integer comparison.
    module FlowTracer
      KEY = :__rigor_flow_tracer__
      private_constant :KEY

      # One animation-relevant moment.
      #
      # kind     :enter | :result | :bind | :union | :dispatch
      # depth    expression-recursion depth at emit time (0 = statement level)
      # location frozen Hash with :start_line/:start_column/:end_line/:end_column/:start_offset/:end_offset, or nil.
      #          Events without a node of their own (:bind, :union) inherit the innermost in-flight expression
      #          node's location so the replayer can still highlight the source being evaluated.
      # stack    frozen Array of short node-class names, outermost first
      # data     frozen kind-specific Hash (types pre-rendered as Strings via `describe(:short)` so events
      #          serialise to JSON as-is)
      Event = Data.define(:kind, :depth, :location, :stack, :data)

      # Mutable per-thread accumulator; only ever touched by the thread that activated it, so no locking is needed
      # on the emit path.
      class Recorder
        attr_reader :events

        def initialize
          @events = []
          @stack = []
        end

        # Brackets one `ExpressionTyper#type_of` recursion: emits :enter, runs the real inference, emits :result
        # with the inferred type, and returns the type unchanged.
        def node(node)
          location = location_of(node)
          name = short_name(node.class)
          emit(:enter, location: location, data: { node: name })
          @stack.push(node)
          result = nil
          begin
            result = yield
          ensure
            @stack.pop
          end
          emit(:result, location: location, data: { node: name, type: FlowTracer.describe(result) })
          result
        end

        def emit(kind, location: nil, data: {})
          @events << Event.new(
            kind: kind,
            depth: @stack.size,
            location: (location || current_location)&.freeze,
            stack: @stack.map { |n| short_name(n.class) }.freeze,
            data: data.freeze
          )
        end

        private

        def current_location
          location_of(@stack.last)
        end

        def location_of(node)
          return nil unless node.respond_to?(:location) && node.location

          loc = node.location
          {
            start_line: loc.start_line, start_column: loc.start_column,
            end_line: loc.end_line, end_column: loc.end_column,
            start_offset: loc.start_offset, end_offset: loc.end_offset
          }
        end

        def short_name(klass)
          klass.name.to_s.split("::").last
        end
      end

      @active_count = 0
      @mutex = Mutex.new

      module_function

      # Activates recording on the current thread for the duration of the block and returns the frozen event list.
      # Nests safely; restores the previous recorder on exit.
      def record
        previous = Thread.current[KEY]
        recorder = Recorder.new
        Thread.current[KEY] = recorder
        @mutex.synchronize { @active_count += 1 }
        yield
        recorder.events.freeze
      ensure
        Thread.current[KEY] = previous
        @mutex.synchronize { @active_count -= 1 }
      end

      # Plain integer read (GVL-atomic) — the disabled fast path.
      def active?
        @active_count.positive?
      end

      # Brackets one expression-typing recursion. Falls through to the bare block when the current thread is not
      # recording (another thread may have flipped {active?}).
      def trace_node(node, &)
        recorder = Thread.current[KEY]
        return yield unless recorder

        recorder.node(node, &)
      end

      # `Scope#with_local` — the moment a local enters the scope.
      def bind(name, type)
        Thread.current[KEY]&.emit(:bind, data: { name: name.to_s, type: describe(type) })
      end

      # `Type::Combinator.union` — the moment branch types merge (including degenerate collapses like `1 | 1 → 1`).
      def union(members, result)
        Thread.current[KEY]&.emit(
          :union,
          data: { members: members.map { |m| describe(m) }.freeze, type: describe(result) }
        )
      end

      # `MethodDispatcher.dispatch` — resolution or the fail-soft `nil` ("no rule matched"; the caller will widen
      # to `Dynamic[Top]`).
      def dispatch(receiver:, method_name:, args:, result:, location: nil)
        recorder = Thread.current[KEY]
        return unless recorder

        recorder.emit(
          :dispatch,
          location: location && location_hash(location),
          data: {
            receiver: describe(receiver), method: method_name.to_s,
            args: args.map { |a| describe(a) }.freeze,
            type: result && describe(result), resolved: !result.nil?
          }
        )
      end

      def describe(type)
        return "nil" if type.nil?
        return type.describe(:short) if type.respond_to?(:describe)

        type.inspect
      end

      def location_hash(loc)
        {
          start_line: loc.start_line, start_column: loc.start_column,
          end_line: loc.end_line, end_column: loc.end_column,
          start_offset: loc.start_offset, end_offset: loc.end_offset
        }
      end
    end
  end
end
