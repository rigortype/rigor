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
    # mutate `self` internally) — disqualifies the local.
    #
    # A missed case is USUALLY only over-conservative (no fold), but the direction is not guaranteed, and an earlier
    # version of this header claimed it was. The counting identity below is about the LOCAL; it says nothing about what
    # happens to a member read's RESULT. `s.x << v` mutates the container `s.x` returns while `s.x` itself is a
    # textbook pure read, so the identity held and the local stayed fold-safe while its member's VALUE changed
    # underneath — `s = Point.new([5]); s.x << "a"; s.x.last` folded to `5` and drew `undefined method 'upcase' for 5`
    # on correct code. That is why {#count_uses} disqualifies a local whose member-read result is itself a receiver
    # (see there). Any future extension must ask the same question: does this shape reach the member's value through
    # something other than the local?
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

        tally = Tally.new(total: Hash.new(0), safe_uses: Hash.new(0), deferred_setter: {}, chained: {})
        count_uses(root, members, tally, false)
        total = tally.total
        safe_uses = tally.safe_uses
        deferred_setter = tally.deferred_setter
        chained = tally.chained

        # A local is fold-safe iff every read of it is a safe use — a pure read OR (ADR-48 slice 4) a
        # straight-line member setter (`n.x = v`) that the setter write-back re-types the binding for.
        # `deferred_setter` disqualifies a local whose setter sits inside a loop / block / lambda, where a
        # single static pass cannot model the setter's per-iteration effect (the write-back would leave a
        # stale binding for the fold to read).
        safe = members.each_key.select do |name|
          writes[name] == 1 && total[name].positive? &&
            total[name] == safe_uses[name] && !deferred_setter[name] && !chained[name]
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
      # The four per-local accumulators pass 2 fills, bundled so the walk stays one recursive call rather than a
      # seven-argument one.
      Tally = Struct.new(:total, :safe_uses, :deferred_setter, :chained, keyword_init: true)

      def count_uses(node, members, tally, deferred)
        return if node.nil?

        tally.total[node.name] += 1 if node.is_a?(Prism::LocalVariableReadNode) && members.key?(node.name)
        chained_local_of(node, members)&.then { |name| tally.chained[name] = true }
        count_receiver_use(node, members, tally, deferred)

        child_deferred = deferred || deferred_boundary?(node)
        each_local_scope_child(node) do |child|
          count_uses(child, members, tally, child_deferred)
        end
      end

      # The `<local>.<call>` arm: a pure read or a member setter counts as a SAFE use of the local, and a setter
      # seen inside a loop / block / lambda additionally marks `deferred_setter`.
      def count_receiver_use(node, members, tally, deferred)
        return unless node.is_a?(Prism::CallNode)

        receiver = node.receiver
        return unless receiver.is_a?(Prism::LocalVariableReadNode) && members.key?(receiver.name)

        member_set = members[receiver.name]
        if pure_read_call?(node, member_set)
          tally.safe_uses[receiver.name] += 1
        elsif member_setter_call?(node, member_set)
          tally.safe_uses[receiver.name] += 1
          tally.deferred_setter[receiver.name] = true if deferred
        end
      end

      # The tracked local behind `<local>.<member>` when THAT read is itself the receiver of a further call —
      # `s.x << v`, `s.x.push(v)`, `row.cells.size`. The counting identity above cannot see these: `s.x` is a
      # pure read of `s` by every measure it applies, and the mutation lands on the object `s.x` RETURNS. The
      # local stays fold-safe, the fold serves the materialisation value, and a correct program is told its
      # accumulated container still holds only what it was built with.
      #
      # Any call on the result disqualifies, with no allow-list of its own. `s.x.to_s` is provably harmless and
      # loses precision here for nothing — but an allow-list is what produced this bug in the first place, and
      # the failure mode of being too broad is a `Dynamic[top]` where a constant would do. Reads that do NOT
      # chain (`dump_type(p.x)`, `assert_type("1", stored.foo)`, a bare `s.x`) are arguments or values, not
      # receivers, and keep folding.
      def chained_local_of(node, members)
        return nil unless node.is_a?(Prism::CallNode)

        inner = node.receiver
        return nil unless inner.is_a?(Prism::CallNode)

        local = inner.receiver
        return nil unless local.is_a?(Prism::LocalVariableReadNode) && members.key?(local.name)

        local.name
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

      # Self-calls that cannot change a member, on top of the receiver's own member READERS. Same list the
      # stored-local scan trusts, so the two halves of the gate cannot drift on what "pure" means. `:class`
      # is added because `self.class.new(...)` is the ordinary way a struct method builds a sibling.
      SELF_PURE_READS = (FIXED_READS + %i[class]).freeze

      # Issue #525 — whether a method body may be granted the `:self` fold-safety sentinel, i.e. whether the
      # caller's member map is still the struct's state at every member read the body performs.
      #
      # Three shapes refuse, and the third is what makes the grant closed under the calls the body makes:
      #
      # 1. a member setter or `[]=` on self (`self.text = v`) — a later read would fold the STALE
      #    construction value, the wrong-type family this gate exists to prevent;
      # 2. a bare `self` anywhere but as a call receiver — passed, stored or returned, `self` reaches code
      #    that can mutate it;
      # 3. any other self-call that is not a member reader or a fixed pure read. `def shout; reset!;
      #    text.upcase; end` over a sibling `def reset!; self.text = ""; end` has no setter of its OWN, so a
      #    guard that only looked for (1) would grant it and fold `text` to the construction value while the
      #    runtime read is `""`.
      #
      # (3) is what makes the grant CLOSED under the calls the body makes. A caller that can resolve sibling
      # methods passes a block: it receives each otherwise-unrecognised self-call name and answers whether
      # that sibling is itself self-fold-safe, which is how `def outer; shout; end` keeps the grant while
      # `def go; reset!; text; end` loses it. Without the block — or for a name the block cannot resolve —
      # the call refuses, so the AST-only answer stays the conservative one.
      #
      # Nested `def` / `class` / `module` bodies are skipped: their statements do not run during THIS body's
      # evaluation. Blocks are descended into — they share `self`.
      #
      # @param body [Prism::Node, nil]
      # @param member_names [Enumerable<Symbol>] the receiver carrier's member names.
      # @yieldparam name [Symbol] an unrecognised self-call selector.
      # @yieldreturn [Boolean] whether that sibling method is itself self-fold-safe.
      def self_fold_safe_body?(body, member_names, &sibling_pure)
        return false if body.nil?

        self_uses_pure?(body, member_names.to_set(&:to_sym), sibling_pure)
      end

      # Recursive worker for {self_fold_safe_body?}. A `SelfNode` reached here came through a non-receiver
      # edge (a call's own `self` receiver is skipped below), so it is an escape.
      def self_uses_pure?(node, members, sibling_pure)
        return true if node.nil? || scope_boundary?(node)
        return false if node.is_a?(Prism::SelfNode)
        # `super` / `super(...)` runs an ancestor's body against this same `self`, and the resolver
        # `sibling_pure` walks owns-class defs only, so nothing here can vouch for what it does. Latent
        # while struct carriers have no subclass ancestry to reach, closed before they do.
        return false if node.is_a?(Prism::SuperNode) || node.is_a?(Prism::ForwardingSuperNode)

        if node.is_a?(Prism::CallNode)
          return false unless self_call_pure?(node, members, sibling_pure)

          return call_children_pure?(node, members, sibling_pure)
        end

        children_pure?(node, members, sibling_pure)
      end

      # A call is pure for this scan unless it targets `self` (explicitly or implicitly) under a name that is
      # neither one of the receiver's member readers nor a fixed pure read. `self.text = v` arrives as a
      # `:text=` call and `self[:text] = v` as `:[]=`; neither is in either set, so both refuse — and neither
      # is offered to `sibling_pure`, since a name that WRITES is not made safe by where it is defined.
      def self_call_pure?(call_node, members, sibling_pure)
        receiver = call_node.receiver
        return true unless receiver.nil? || receiver.is_a?(Prism::SelfNode)

        name = call_node.name
        return true if members.include?(name) || SELF_PURE_READS.include?(name)
        return false if writer_selector?(name)

        !sibling_pure.nil? && sibling_pure.call(name)
      end

      # A selector that assigns: `text=`, `[]=`. Never delegated to `sibling_pure` — a writer is unsafe on
      # its face, and asking the resolver about it would let a struct with a hand-written `def text=(v)` that
      # the resolver walks into read as pure.
      def writer_selector?(name)
        text = name.to_s
        text.end_with?("=") && !%w[== != <= >= ===].include?(text)
      end

      # Children of a call, skipping an explicit `self` RECEIVER — that occurrence is the call's own target
      # and was already judged by {self_call_pure?}, not an escape.
      def call_children_pure?(call_node, members, sibling_pure)
        call_node.rigor_each_child do |child|
          next if child.is_a?(Prism::SelfNode) && child.equal?(call_node.receiver)
          return false unless self_uses_pure?(child, members, sibling_pure)
        end
        true
      end

      def children_pure?(node, members, sibling_pure)
        node.rigor_each_child do |child|
          return false unless self_uses_pure?(child, members, sibling_pure)
        end
        true
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
