# frozen_string_literal: true

require "prism"

require_relative "../source/constant_path"
require_relative "../source/node_children"

module Rigor
  module Inference
    # ADR-48 Struct follow-up, slice 3 — the fold-safe-local scan. Determines, for a single local-variable scope (a
    # method body or the program top-level), which `Struct`-materialised locals are **provably never mutated, aliased,
    # or escaped** and so may have their member reads folded off a *stored* binding (relaxing the slice-2 fresh-receiver
    # gate).
    #
    # The analysis is a conservative ALLOW-LIST, not a deny-list: a local is fold-safe only when *every* read of it is
    # the receiver of a known-pure read call. Anything the scan does not recognise as a pure read — a setter, an `[]=` /
    # operator-write, an argument / alias / container store / return (escape), or an unknown method call (which could
    # mutate `self` internally) — disqualifies the local. A missed case therefore makes the scan over-conservative (no
    # fold), **never unsound** (folding a mutated value) — the false-positive-safe direction.
    #
    # Soundness rests on a counting identity: a local `n` is fold-safe iff *every* `LocalVariableReadNode(n)` is the
    # receiver of a pure-read call. Equivalently `total_reads(n) == pure_receiver_reads(n)`. Any other occurrence — `n`
    # as a setter receiver (`n.x = v` is a `:x=` call, not a pure read), an `[]=`/operator-write receiver (the receiver
    # read is not under a pure call), a call argument, an assignment RHS (alias), a container element, a bare value
    # (return/escape) — leaves a read that is not a pure-receiver read, so the counts diverge.
    #
    # See docs/notes/20260615-struct-folding-slice3-design.md and docs/adr/48-data-struct-value-folding.md § "Struct
    # follow-up".
    module StructFoldSafety
      module_function

      EMPTY = Set.new.freeze

      # The fixed `Struct` read methods that never mutate. A member-reader name (`:x`) is added per-local from the
      # local's recorded layout. A setter (`:x=`), `:[]=`, `store`, `push`, etc. are deliberately absent.
      FIXED_READS = %i[
        [] dig to_h to_hash to_a values members deconstruct deconstruct_keys
        == != eql? equal? hash inspect to_s size length frozen? each each_pair
        values_at with
      ].to_set.freeze

      # Nested `def` / `class` / `module` bodies open a *new* local-variable scope, so the scan does not descend into
      # them — a local of the same name there is a different binding. Blocks share the enclosing locals (closures), so
      # the scan does descend into them.
      def scope_boundary?(node)
        node.is_a?(Prism::DefNode) || node.is_a?(Prism::ClassNode) ||
          node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::SingletonClassNode)
      end

      # @param root [Prism::Node, nil] the local-variable scope to scan.
      # @param layout_lookup [#call] a `String -> Array[Symbol] | nil` resolver mapping a constant receiver name to its
      #   struct member list.
      # @return [Set<Symbol>] the fold-safe local names.
      def fold_safe_locals(root, layout_lookup)
        return EMPTY if root.nil?

        members = {}
        writes = Hash.new(0)
        collect_struct_locals(root, layout_lookup, members, writes)
        return EMPTY if members.empty?

        total = Hash.new(0)
        safe_uses = Hash.new(0)
        deferred_setter = {}
        count_uses(root, members, total, safe_uses, deferred_setter, false)

        # A local is fold-safe iff every read of it is a safe use — a pure read OR (ADR-48 slice 4) a
        # straight-line member setter (`n.x = v`) that the setter write-back re-types the binding for.
        # `deferred_setter` disqualifies a local whose setter sits inside a loop / block / lambda, where a
        # single static pass cannot model the setter's per-iteration effect (the write-back would leave a
        # stale binding for the fold to read).
        safe = members.each_key.select do |name|
          writes[name] == 1 && total[name].positive? &&
            total[name] == safe_uses[name] && !deferred_setter[name]
        end
        safe.empty? ? EMPTY : safe.to_set
      end

      # Pass 1 — record each local's single struct materialisation (its member set) and count its assignments. A local
      # assigned more than once is later excluded (the static fold-safe set cannot track a rebinding).
      def collect_struct_locals(node, layout_lookup, members, writes)
        return if node.nil?

        if node.is_a?(Prism::LocalVariableWriteNode)
          writes[node.name] += 1
          found = struct_materialization_members(node.value, layout_lookup)
          members[node.name] = found if found
        end

        each_local_scope_child(node) do |child|
          collect_struct_locals(child, layout_lookup, members, writes)
        end
      end

      # Pass 2 — count, per recorded struct local, total reads vs. SAFE-use reads (the receiver of a pure-read call,
      # or of a straight-line member setter). `deferred` is true inside a loop / block / lambda; a member setter seen
      # there marks the local's `deferred_setter` so it is excluded (its write-back cannot be modelled statically).
      def count_uses(node, members, total, safe_uses, deferred_setter, deferred)
        return if node.nil?

        total[node.name] += 1 if node.is_a?(Prism::LocalVariableReadNode) && members.key?(node.name)

        if node.is_a?(Prism::CallNode)
          receiver = node.receiver
          if receiver.is_a?(Prism::LocalVariableReadNode) && members.key?(receiver.name)
            member_set = members[receiver.name]
            if pure_read_call?(node, member_set)
              safe_uses[receiver.name] += 1
            elsif member_setter_call?(node, member_set)
              safe_uses[receiver.name] += 1
              deferred_setter[receiver.name] = true if deferred
            end
          end
        end

        child_deferred = deferred || deferred_boundary?(node)
        each_local_scope_child(node) do |child|
          count_uses(child, members, total, safe_uses, deferred_setter, child_deferred)
        end
      end

      # A call is a pure read of the receiver when its name is a fixed Struct read or one of the receiver's member
      # readers. Setters (`:x=`), `:[]=`, and any unknown method are excluded.
      def pure_read_call?(call_node, member_set)
        name = call_node.name
        FIXED_READS.include?(name) || member_set.include?(name)
      end

      # A `n.<member> = v` attribute setter on the receiver (ADR-48 slice 4): the selector strips its trailing `=` to
      # a member reader and the call carries exactly one argument. Comparison operators (`==`, `>=`, `!=`) also end
      # with `=` but never strip to a member, so they stay unknown (unsafe) calls. `:[]=` is likewise not a member.
      def member_setter_call?(call_node, member_set)
        name = call_node.name.to_s
        return false unless name.length > 1 && name.end_with?("=")
        return false unless member_set.include?(name[0..-2].to_sym)

        (call_node.arguments&.arguments&.size || 0) == 1
      end

      # Constructs whose body runs zero-or-many times or is deferred (loops, blocks, lambdas): a single static pass
      # over the body cannot model a member setter's effect across iterations, so a setter inside one disqualifies the
      # local. Straight-line conditionals (`if` / `unless` / `case`) are NOT boundaries — their branch scopes join
      # soundly, so a setter in one branch is fine.
      def deferred_boundary?(node)
        node.is_a?(Prism::WhileNode) || node.is_a?(Prism::UntilNode) ||
          node.is_a?(Prism::ForNode) || node.is_a?(Prism::BlockNode) ||
          node.is_a?(Prism::LambdaNode)
      end

      # The member set of a `<Struct chain>.new(...)` / `.[]` materialisation, or nil. Handles the inline
      # `Struct.new(:a, :b).new(...)` form and the `Const.new(...)` form (resolved through the layout side-table).
      def struct_materialization_members(value_node, layout_lookup)
        return nil unless value_node.is_a?(Prism::CallNode)
        return nil unless %i[new []].include?(value_node.name)

        receiver = value_node.receiver
        case receiver
        when Prism::CallNode
          struct_new_member_set(receiver)

        when Prism::ConstantReadNode, Prism::ConstantPathNode
          name = Source::ConstantPath.qualified_name_or_nil(receiver)
          name && member_set_of(layout_lookup.call(name))
        end
      end

      # The Symbol member set of a literal `Struct.new(:a, :b [, keyword_init:])` call, or nil. (A leading String name
      # and the trailing options hash are ignored — only the literal-Symbol positionals contribute.)
      def struct_new_member_set(call_node)
        return nil unless call_node.is_a?(Prism::CallNode) && call_node.name == :new
        return nil unless meta_constant?(call_node.receiver, :Struct)

        args = call_node.arguments&.arguments || []
        # `[0..-2]` cannot return nil for a start of 0, but `Array#[](Range) -> Array[T]?` says it can;
        # the `|| []` keeps the read well-typed on that worst case.
        positional = args.last.is_a?(Prism::KeywordHashNode) ? (args[0..-2] || []) : args
        positional = positional[1..] if positional.first.is_a?(Prism::StringNode)
        return nil if positional.nil? || positional.empty?
        return nil unless positional.all?(Prism::SymbolNode)

        positional.to_set { |sym| sym.unescaped.to_sym }
      end

      def member_set_of(members)
        members && !members.empty? ? members.to_set : nil
      end

      def meta_constant?(node, name)
        case node
        when Prism::ConstantReadNode then node.name == name
        when Prism::ConstantPathNode then node.parent.nil? && node.name == name
        end
      end

      # Yields each child to recurse into, skipping the subtree of a nested local-variable-scope boundary (a `def` /
      # `class` / `module`).
      def each_local_scope_child(node)
        node.rigor_each_child do |child|
          next if scope_boundary?(child)

          yield child
        end
      end
    end
  end
end
