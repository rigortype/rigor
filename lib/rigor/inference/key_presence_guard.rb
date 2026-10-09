# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "mutation_widening"
require_relative "key_presence_guard/scan"

module Rigor
  module Inference
    # Issue #1703 — `H.key?(k)` / `has_key?` / `include?` / `member?` with a non-literal key, followed by `H[k]`.
    #
    # A closed hash shape read by a computed key answers every value plus the miss `nil`
    # (`ShapeDispatch#hash_dig_step`), so the guarded read in typelizer's
    # `COLUMN_TYPE_MAP.key?(property.column_type) && …; COLUMN_TYPE_MAP[property.column_type].dup` kept the `nil`
    # and its `[]=` reported `call.possible-nil-receiver`.
    #
    # **Fail-closed by construction.** The analysis every rule reads never records a guard: {.record} and
    # {.guarded_read} act only inside {.with_guards}, which nothing but {.withholds_nil?} enters. When
    # `call.possible-nil-receiver` is about to report on a file that holds a guard-shaped call, it re-walks the file
    # once with guards on, from a scope whose side tables are private copies, and withholds the report only when the
    # re-walk types the receiver as exactly the analysis's type without `nil`. No other type, verdict, summary or
    # signature can change, so the guard can only remove that one report.
    #
    # Inside the re-walk a guard is recorded only when it is safe to rely on ({.eligible?}) and is dropped where the
    # receiver or the key may have changed ({.invalidate_after_call}, {.invalidate_after_write}, a rebinding through
    # `Scope#bind_local` / `#bind_ivar`, and the region check in {.guarded_read}).
    module KeyPresenceGuard
      # The key half of a guard's address: a local, an instance variable, or a chain of plain readers rooted at one
      # (`prop.column_type`). `path` is `[[root_kind, root_name], method, …]`, so two spellings of one chain compare
      # equal.
      KeyExpr = Data.define(:path) do
        def root = path.first

        # Whether `other` reads a prefix of this chain (`prop` or `prop.column_type` for `prop.column_type`), so
        # evaluating it re-reads this key rather than intervening.
        def prefixed_by?(other) = path.first(other.path.size) == other.path
      end

      # What a guard stores at its address. The fact is the entry's presence on every joined arm; the read
      # recomputes its type from the receiver, so the value carries nothing.
      PRESENT = Type::Combinator.constant_of(true)

      PREDICATES = %i[key? has_key? include? member?].to_set.freeze

      # A plain reader's name: lower-case, no operator, writer or bang.
      READER_NAME = /\A[a-z_][a-z0-9_]*\??\z/

      # Reader-shaped names that answer something new on each call or consume state, so `h.key?(q.shift)` and a later
      # `h[q.shift]` read different keys. Every name the mutation tables know is excluded too.
      NON_IDEMPOTENT_READERS = (
        %i[
          shift pop unshift push append prepend next succ pred gets read readline readlines readpartial read_nonblock
          getc getbyte readchar readbyte each each_line each_char each_byte rand random sample shuffle tick now call
          yield resume take take_while drop lazy to_enum enum_for peek rewind reload reset lock unlock clear
          generate fetch_next dequeue deq enqueue enq poll receive recv accept consume
        ] + MutationWidening::SHAPE_MUTATORS.to_a
      ).to_set.freeze

      STATE_KEY = :__rigor_key_presence_guard
      CACHE_KEY = :__rigor_key_presence_guard_rewalk
      private_constant :STATE_KEY, :CACHE_KEY

      # The re-walk's state: the file's root, the end offset of each recorded guard, and the per-file scans.
      Walk = Struct.new(:root, :guard_ends, :defs, :frozen_constants) do
        def enclosing_def(node)
          self.defs ||= collect_defs(root, [])
          offset = node.location.start_offset
          defs.select { |d| d.location.start_offset <= offset && offset < d.location.end_offset }
              .min_by { |d| d.location.end_offset - d.location.start_offset }
        end

        def collect_defs(node, out)
          out << node if node.is_a?(Prism::DefNode)
          node.compact_child_nodes.each { |child| collect_defs(child, out) }
          out
        end
      end

      module_function

      # Runs the block with guards recorded and read, for the re-walk of `root`. Thread-local, so it holds under a
      # Ractor worker too.
      def with_guards(root)
        previous = Thread.current[STATE_KEY]
        Thread.current[STATE_KEY] = Walk.new(root, {})
        yield
      ensure
        Thread.current[STATE_KEY] = previous
      end

      # Runs the block with guards off again: a callee's return summary, memoised for the whole run, must be the one
      # the file's analysis reads.
      def without_guards
        previous = Thread.current[STATE_KEY]
        Thread.current[STATE_KEY] = nil
        yield
      ensure
        Thread.current[STATE_KEY] = previous
      end

      def active? = !Thread.current[STATE_KEY].nil?

      # Whether `call.possible-nil-receiver` should withhold its report on `call_node`, whose receiver the file's
      # analysis types `receiver_type`: true only when the guarded re-walk types that receiver as exactly
      # `receiver_type` without `nil`. False for a file with no guard-shaped call, while an effect or flow trace
      # records the walk, and on any failure.
      def withholds_nil?(call_node, receiver_type, root, scope_index)
        return false if root.nil? || active?
        return false if Effects::Collector.active? || FlowTracer.active?

        guarded_index = rewalk(root, scope_index)
        scope = guarded_index && guarded_index[call_node]
        return false if scope.nil?

        guarded_type = with_guards(root) { scope.type_of(call_node.receiver) }
        expected = Narrowing.narrow_non_nil(receiver_type)
        !expected.equal?(receiver_type) && expected == guarded_type && guarded_type != receiver_type
      rescue StandardError
        false
      end

      # The guarded scope index of `root`, built once per file (the cache holds the last file only), or nil when the
      # file holds no guard-shaped call.
      def rewalk(root, scope_index)
        cached = Thread.current[CACHE_KEY]
        return cached.last if cached&.first.equal?(root)

        index = nil
        if guard_shaped_call?(root)
          base = scope_index[root]
          index = base && with_guards(root) do
            ScopeIndexer.index(root, default_scope: base.with_isolated_side_tables)
          end
        end
        Thread.current[CACHE_KEY] = [root, index]
        index
      end

      def guard_shaped_call?(node)
        if node.is_a?(Prism::CallNode) && PREDICATES.include?(node.name)
          args = node.arguments&.arguments
          return true if args&.size == 1 && address(node.receiver, args.first)
        end
        node.compact_child_nodes.any? { |child| guard_shaped_call?(child) }
      end

      # The {KeyExpr} for `node`, or nil unless it is a local / ivar read or a chain of plain, idempotent readers
      # (no argument, block or `&.`) rooted at one. A literal key is the shape path's business and answers nil.
      def key_expr(node)
        case node
        when Prism::LocalVariableReadNode then KeyExpr.new(path: [[:local, node.name]].freeze)
        when Prism::InstanceVariableReadNode then KeyExpr.new(path: [[:ivar, node.name]].freeze)
        when Prism::CallNode
          return nil unless plain_reader_call?(node)

          inner = key_expr(node.receiver)
          inner && KeyExpr.new(path: (inner.path + [node.name]).freeze)
        end
      end

      def plain_reader_call?(node)
        node.receiver && node.block.nil? && node.arguments.nil? && !node.safe_navigation? &&
          READER_NAME.match?(node.name) && !NON_IDEMPOTENT_READERS.include?(node.name)
      end

      # The receiver half of a guard's address: a local, an instance variable or a constant read.
      def receiver_ref(node)
        case node
        when Prism::LocalVariableReadNode then [:local, node.name]
        when Prism::InstanceVariableReadNode then [:ivar, node.name]
        when Prism::ConstantReadNode then [:const, node.name]
        end
      end

      # `[receiver_kind, receiver_name, KeyExpr]` for `receiver[key]` / `receiver.key?(key)`, or nil.
      def address(receiver_node, key_node)
        receiver = receiver_ref(receiver_node)
        return nil if receiver.nil?

        key = key_expr(key_node)
        key && [receiver.first, receiver.last, key]
      end

      # A closed, non-empty hash shape (or a union of them): the carrier whose computed-key read carries the miss
      # `nil`. An RBS `Hash[K, V]` read is already nil-free; an open shape or a user class answering `key?` is left
      # alone.
      def receiver_type?(type)
        if type.is_a?(Type::Union)
          type.members.all? { |member| closed_shape?(member) }
        else
          closed_shape?(type)
        end
      end

      def closed_shape?(type) = type.is_a?(Type::HashShape) && type.closed? && !type.pairs.empty?

      # The truthy edge of `receiver.key?(key)` with a non-literal key, inside the re-walk: `scope` with the guard
      # recorded, or nil when the guard does not apply.
      def record(call_node, scope)
        walk = Thread.current[STATE_KEY]
        return nil if walk.nil?

        args = call_node.arguments&.arguments
        return nil unless args&.size == 1

        guard = address(call_node.receiver, args.first)
        return nil if guard.nil?
        return nil unless receiver_type?(scope.type_of(call_node.receiver))
        return nil unless Scan.eligible?(walk, call_node, guard)

        walk.guard_ends[guard] = call_node.location.end_offset
        scope.with_indexed_narrowing(*guard, PRESENT)
      end

      # `type`, the un-narrowed answer of the read `node`, with the miss `nil` dropped when, inside the re-walk, a
      # guard on the same receiver and structurally the same key holds in `scope`, nothing between the guard and the
      # read may have changed it ({.intervening?}), and no value of the receiver can be `nil` (the read cannot tell a
      # value's own `nil` from the miss). Nil when no guard applies or nothing would change.
      def guarded_read(node, type, scope)
        walk = Thread.current[STATE_KEY]
        guard = walk && held_guard(node, scope)
        return nil if guard.nil? || Scan.intervening?(walk, guard, node)

        receiver_type = scope.type_of(node.receiver)
        return nil unless receiver_type?(receiver_type) && nil_free_values?(receiver_type)

        narrowed = Narrowing.narrow_non_nil(type)
        narrowed == type || narrowed.is_a?(Type::Bot) ? nil : narrowed
      end

      # The guard `scope` holds at the address of the blockless single-key read `node`, or nil.
      def held_guard(node, scope)
        return nil if !node.block.nil? || !any_guard?(scope)

        args = node.arguments&.arguments
        guard = args&.size == 1 ? address(node.receiver, args.first) : nil
        guard && !scope.indexed_narrowing(*guard).nil? ? guard : nil
      end

      def nil_free_values?(receiver_type)
        shapes = receiver_type.is_a?(Type::Union) ? receiver_type.members : [receiver_type]
        shapes.none? { |shape| shape.pairs.each_value.any? { |value| value_may_be_nil?(value) } }
      end

      # Whether `scope` holds any guard. Walks the keys without allocating, so the common no-guard case costs a size
      # check.
      def any_guard?(scope)
        table = scope.indexed_narrowings
        return false if table.empty?

        table.each_key { |key| return true if key.key.is_a?(KeyExpr) }
        false
      end

      def value_may_be_nil?(value)
        case value
        when Type::Top then true
        when Type::Constant then value.value.nil?
        when Type::Nominal then value.class_name == "NilClass"
        when Type::Union then value.members.any? { |member| value_may_be_nil?(member) }
        else false
        end
      end

      # Drops the guards `call_node` may break. Always-safe (only forgets; never invents).
      def invalidate_after_call(call_node, scope)
        return scope unless call_node.is_a?(Prism::CallNode) && any_guard?(scope)

        drop_guards(scope) { |guard| Scan.breaks?(call_node, triple(guard)) }
      end

      # Drops the guards a write aliases: one whose value holds the guarded receiver or the key's root variable
      # (`g = h`, `j = k`, `@cache = [MAP]`), since the copy may then be mutated or rebound out of sight.
      def invalidate_after_write(node, scope)
        return scope unless Scan::WRITE_NODES.include?(node.class) && any_guard?(scope)

        drop_guards(scope) do |guard|
          Scan.aliases_guard?(node, triple(guard))
        end
      end

      def triple(guard) = [guard.receiver_kind, guard.receiver_name, guard.key]

      def drop_guards(scope)
        result = scope
        scope.indexed_narrowings.each_key do |guard|
          next unless guard.key.is_a?(KeyExpr) && yield(guard)

          result = result.without_indexed_narrowing(guard.receiver_kind, guard.receiver_name, guard.key)
        end
        result
      end
    end
  end
end
