# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    module KeyPresenceGuard
      # Issue #1703 — the syntax scans {KeyPresenceGuard} decides with: whether a guard may be relied on at all
      # ({.eligible?}), whether the source between a guard and its read may have broken it ({.intervening?}), and
      # whether one call or write breaks it ({.breaks?}, {.aliases_guard?}). Every answer errs towards breaking.
      module Scan
        # Blockless calls on a guarded receiver that cannot remove a key or rebind a slot, and do not answer the
        # receiver itself (so `x = h.itself` or `x = h.to_h` is a hand-on, not a read). Any other call on it, and any
        # call with a block, may break the guard (`h.delete(k)`, `h.send(:delete, k)`, `h.each { … h.clear }`).
        READ_ONLY_RECEIVER_CALLS = %i[
          [] key? has_key? include? member? fetch dig values_at fetch_values size length count empty? any? none?
          keys values to_a dup clone frozen? hash == != eql? equal? inspect to_s is_a? kind_of? instance_of? nil?
          respond_to?
        ].to_set.freeze

        # The nodes whose `value` a write stores: storing the receiver or the key's root somewhere else aliases it.
        WRITE_NODES = [
          Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode,
          Prism::GlobalVariableWriteNode, Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::MultiWriteNode,
          Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode, Prism::LocalVariableOperatorWriteNode,
          Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
          Prism::InstanceVariableOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode,
          Prism::IndexOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode, Prism::CallOperatorWriteNode
        ].to_set.freeze

        # The nodes that bind a local by name (a write, or a target of a multiple assignment, `for`, `rescue => e`, a
        # pattern or a named capture) and an instance variable by name.
        LOCAL_BINDERS = [
          Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
          Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableTargetNode
        ].to_set.freeze

        IVAR_BINDERS = [
          Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableAndWriteNode,
          Prism::InstanceVariableOperatorWriteNode, Prism::InstanceVariableTargetNode
        ].to_set.freeze

        CLOSURE_NODES = [Prism::BlockNode, Prism::LambdaNode].to_set.freeze

        private_constant :LOCAL_BINDERS, :IVAR_BINDERS, :CLOSURE_NODES

        module_function

        # A guard is relied on only when nothing in reach can change what it proved:
        # - a local receiver is never handed on in its method body — as an argument, a written value, inside a block, or
        #   as the receiver of anything but a blockless read ({.mentions?}) — before the guard or after it;
        # - an instance-variable receiver is never handed on anywhere in the file;
        # - a constant receiver is assigned once in the file, a frozen hash literal (`MAP = { … }.freeze`), and is never
        #   handed on in the file;
        # - a local key root is bound nowhere in its method body after the guard, never stored elsewhere (`j = k`) and
        #   never read inside a block; an instance-variable key root is bound nowhere in the file.
        def eligible?(walk, call_node, guard)
          kind, name, key = guard
          body = walk.enclosing_def(call_node) || walk.root
          receiver_eligible?(walk, body, kind, name) && key_root_eligible?(walk, body, key, call_node)
        end

        # Memoised per receiver and, for a local, per method body: the answer depends on neither the guard nor its key.
        def receiver_eligible?(walk, body, kind, name)
          memo_key = [:receiver, kind, name, kind == :local ? body.location.start_offset : nil]
          return walk.memo[memo_key] if walk.memo.key?(memo_key)

          walk.memo[memo_key] = scan_receiver_eligible?(walk, body, kind, name)
        end

        def scan_receiver_eligible?(walk, body, kind, name)
          case kind
          when :local then !mentions?(body, [kind, name])
          when :ivar then !mentions?(walk.root, [kind, name])
          when :const then frozen_constant?(walk, name) && !mentions?(walk.root, [kind, name])
          else false
          end
        end

        def frozen_constant?(walk, name)
          walk.frozen_constants ||= frozen_constant_names(walk.root)
          walk.frozen_constants.include?(name)
        end

        # The constants the file assigns exactly once, to a frozen hash literal.
        def frozen_constant_names(root)
          writes = Hash.new { |table, key| table[key] = [] }
          collect_constant_writes(root, writes)
          writes.filter_map { |name, values| name if values.size == 1 && frozen_hash_literal?(values.first) }.to_set
        end

        def collect_constant_writes(node, writes)
          writes[node.name] << node.value if node.is_a?(Prism::ConstantWriteNode)
          writes[node.name] << nil if node.is_a?(Prism::ConstantOrWriteNode) || node.is_a?(Prism::ConstantTargetNode)
          node.compact_child_nodes.each { |child| collect_constant_writes(child, writes) }
        end

        def frozen_hash_literal?(value)
          value.is_a?(Prism::CallNode) && value.name == :freeze && value.arguments.nil? && value.block.nil? &&
            value.receiver.is_a?(Prism::HashNode)
        end

        def key_root_eligible?(walk, body, key, guard_node)
          root_ref = key.root
          kind, name = root_ref
          if kind == :ivar
            memo_key = [:ivar_key_root, name]
            return walk.memo[memo_key] if walk.memo.key?(memo_key)

            walk.memo[memo_key] = !binds?(walk.root, IVAR_BINDERS, name, -1) && !closure_reads?(walk.root, root_ref)
          else
            !binds?(body, LOCAL_BINDERS, name, guard_node.location.start_offset) &&
              !aliases?(body, key) && !closure_reads?(body, root_ref)
          end
        end

        # Whether a binder of `name` starts after `offset` within `node`.
        def binds?(node, binders, name, offset)
          return true if binders.include?(node.class) && node.name == name && node.location.start_offset > offset

          node.compact_child_nodes.any? { |child| binds?(child, binders, name, offset) }
        end

        # Whether a write stores the key's value or something a call on it answers (`j = k`, `s = k.itself`,
        # `s = prop.column_type.to_s`): its value is the key's root read, or a receiver chain that starts with the
        # whole key chain. Such a copy may be the key object itself, and mutating it changes the key.
        def aliases?(node, key)
          return true if WRITE_NODES.include?(node.class) && derived_from_key?(node.value, key)

          node.compact_child_nodes.any? { |child| aliases?(child, key) }
        end

        def derived_from_key?(value, key)
          path = receiver_path(value)
          !path.nil? && path.first(key.path.size) == key.path
        end

        # `[[root_kind, root_name], method, …]` for a local / ivar read or a receiver chain rooted at one, or nil.
        def receiver_path(node)
          names = []
          while node.is_a?(Prism::CallNode) && node.receiver
            names.unshift(node.name)
            node = node.receiver
          end
          root = chain_root(node)
          root && [root, *names]
        end

        # Whether a block or lambda body reads `ref` at all.
        def closure_reads?(node, ref)
          return reads?(node, ref) if CLOSURE_NODES.include?(node.class)

          node.compact_child_nodes.any? { |child| closure_reads?(child, ref) }
        end

        def reads?(node, ref)
          receiver_ref(node) == ref || node.compact_child_nodes.any? { |child| reads?(child, ref) }
        end

        # Whether the source between the guard and the read holds anything that may break the guard, read in source
        # order so a later operand of the guard's own condition counts (`h.key?(k) && purge(h, k)`). A read before its
        # guard (a loop back-edge) is taken to intervene.
        def intervening?(walk, guard, read_node)
          start = walk.guard_ends[guard]
          stop = read_node.location.start_offset
          return true if start.nil? || start > stop

          body = walk.enclosing_def(read_node) || walk.root
          breaks_in_region?(body, guard, start, stop)
        end

        def breaks_in_region?(node, guard, start, stop)
          location = node.location
          return false if location.end_offset <= start || location.start_offset >= stop

          return true if location.start_offset >= start && location.end_offset <= stop && node_breaks?(node, guard)

          node.compact_child_nodes.any? { |child| breaks_in_region?(child, guard, start, stop) }
        end

        def node_breaks?(node, guard)
          (node.is_a?(Prism::CallNode) && breaks?(node, guard)) ||
            (WRITE_NODES.include?(node.class) && aliases_guard?(node, guard)) ||
            rebinds_guard?(node, guard) ||
            (CLOSURE_NODES.include?(node.class) && closure_breaks?(node, guard))
        end

        def aliases_guard?(node, guard)
          kind, name, key = guard
          mentions?(node.value, [kind, name]) || mentions?(node.value, key.root)
        end

        def rebinds_guard?(node, guard)
          kind, name, key = guard
          [[kind, name], key.root].any? do |ref_kind, ref_name|
            binders = { local: LOCAL_BINDERS, ivar: IVAR_BINDERS }[ref_kind]
            binders&.include?(node.class) && node.name == ref_name
          end
        end

        def closure_breaks?(node, guard)
          kind, name, key = guard
          reads?(node, [kind, name]) || reads?(node, key.root)
        end

        # Whether `call_node` may break the guard `[receiver_kind, receiver_name, key]`:
        # - it passes the receiver as an argument (or `self`, when an instance variable is involved), or its block
        #   mentions the receiver or the key's root;
        # - it is a call on the receiver other than a blockless read ({READ_ONLY_RECEIVER_CALLS});
        # - it is rooted at the key's variable and does not re-read the key chain (`prop.reload`, `prop.x = 1`);
        # - it is a call on `self` and the receiver or the key is an instance variable.
        # Passing the key's root as an argument (`overridden?(prop)`) does not break it, as it does not end a
        # method-chain narrowing.
        def breaks?(call_node, guard)
          kind, name, key = guard
          receiver_ref = [kind, name]
          return true if escapes_through_operands?(call_node, receiver_ref, key.root)

          receiver = call_node.receiver
          return kind == :ivar || key.root.first == :ivar if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          return true if receiver_ref(receiver) == receiver_ref && !read_only_call?(call_node)

          touches_key_root?(call_node, key)
        end

        def escapes_through_operands?(call_node, receiver_ref, key_root)
          args = call_node.arguments
          return true if args && mentions?(args, receiver_ref)
          # `other.mutate_owner(self)` hands on every instance variable.
          return true if args && (receiver_ref.first == :ivar || key_root.first == :ivar) && mentions_self?(args)

          block = call_node.block
          return false if block.nil?

          mentions?(block, receiver_ref) || (block.is_a?(Prism::BlockNode) && reads?(block, key_root))
        end

        def read_only_call?(call_node) = call_node.block.nil? && READ_ONLY_RECEIVER_CALLS.include?(call_node.name)

        def touches_key_root?(call_node, key)
          return false unless chain_root(call_node.receiver) == key.root

          own = key_expr(call_node)
          own.nil? || !key.prefixed_by?(own)
        end

        # The `[kind, name]` of the local / ivar a receiver chain (`a.b.c`, `a[0].b`) starts from, or nil.
        def chain_root(node)
          node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver
          case node
          when Prism::LocalVariableReadNode then [:local, node.name]
          when Prism::InstanceVariableReadNode then [:ivar, node.name]
          end
        end

        def mentions_self?(node)
          node.is_a?(Prism::SelfNode) || node.compact_child_nodes.any? { |child| mentions_self?(child) }
        end

        # Whether `node` holds a read of the variable `ref` in a position that may hand it on: anywhere but as the
        # receiver of a blockless read ({READ_ONLY_RECEIVER_CALLS}), so `h[k]` and `MAP.key?(x)` do not count while
        # `zap(h)`, `[h]`, `g = h` and `h.delete(k)` do.
        def mentions?(node, ref)
          return false if node.nil?

          own = receiver_ref(node)
          return own == ref if own

          if node.is_a?(Prism::CallNode) && receiver_ref(node.receiver) == ref && read_only_call?(node)
            return [node.arguments, node.block].any? { |part| mentions?(part, ref) }
          end

          node.compact_child_nodes.any? { |child| mentions?(child, ref) }
        end

        def receiver_ref(node) = KeyPresenceGuard.receiver_ref(node)
        def key_expr(node) = KeyPresenceGuard.key_expr(node)
      end
    end
  end
end
