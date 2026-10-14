# frozen_string_literal: true

require_relative "../type"
require_relative "../source/node_walker"
require_relative "captured_locals"

module Rigor
  module Inference
    # Issue #1840 — a branch merge that re-joins the narrowed edges of an untyped local gives it back its
    # untyped binding.
    #
    # Flow narrowing concretizes a `Dynamic[top]` receiver (ADR-83): `x.nil?` splits it into `nil` and
    # `Dynamic[top]`, and `when String` into `String` and `Dynamic[top]`. `Scope#join` unions the edges, so
    # after both merges the local reads `Dynamic[top] | String | nil`. That union is not wrong as a set, but
    # every member is a narrowing of the one untyped value, so it says nothing the pre-branch binding did
    # not. It does, however, hold `nil` beside a nameable class, and `call.possible-nil-receiver` reports
    # `x + "a"` on correct code although neither narrowing alone did.
    #
    # The rule: at a merge, a local whose pre-branch binding is exactly `Dynamic[top]`, that no merged arm
    # writes, and whose joined binding is a union still carrying a `Dynamic` member, is bound to
    # `Dynamic[top]` again.
    #
    # - The write test keeps a nil the program puts there: `x = nil if c` writes `x`, so the join stays
    #   `Dynamic[top] | nil` and still reports. It is syntactic, over every local-write form under the arms
    #   (a pattern capture and a block's write to the outer local included), so a doubtful arm keeps today's
    #   join. It does not see a written nil that a `nil?` edge stripped before the merge (`x = nil if c; if
    #   x.nil? … elsif x.is_a?(String) … end`): that merge's entry is exactly `Dynamic[top]`, and the outer
    #   join's `Dynamic[top] | nil` is one the possible-nil gate declines anyway (#1840-follow-up).
    # - The `Dynamic`-member test keeps a narrowing whose surviving arms no longer cover the untyped value:
    #   `case x when String then … when Integer then … else raise end` leaves `Integer | String`, which is
    #   what `x` is past it.
    # - Only the `Dynamic[top]` facet: a faceted `Dynamic[T]` carries static knowledge of its own (a
    #   plugin's or a signature's `T`), so a `nil` its narrowing leaves may be one the facet promised. Those
    #   keep today's join.
    #
    # Restoring `Dynamic[top]` is always sound, since every narrowed edge is a subset of it; what it drops
    # is only the nameable arms, which an untyped union never needed to dispatch.
    module UntypedRejoin
      module_function

      # `joined` with each qualifying local rebound to its `entry` binding. `arms` are the nodes whose
      # evaluation produced the merged scopes (`nil` entries are skipped).
      def apply(joined, entry, arms)
        candidates = nil
        joined.locals.each do |name, type|
          next unless candidate?(entry.locals[name], type)

          (candidates ||= []) << name
        end
        return joined if candidates.nil?

        written = written_locals(arms)
        kept = candidates.reject { |name| written.include?(name) }
        return joined if kept.empty?

        joined.with_rejoined_locals(kept.to_h { |name| [name, entry.locals[name]] })
      end

      def candidate?(entry_type, joined_type)
        entry_type.is_a?(Type::Dynamic) && entry_type.static_facet.is_a?(Type::Top) &&
          joined_type.is_a?(Type::Union) && joined_type.members.any?(Type::Dynamic)
      end

      def written_locals(arms)
        names = Set.new
        arms.each do |arm|
          Source::NodeWalker.each(arm) do |node|
            names << node.name if CapturedLocals::LOCAL_WRITE_NODES.include?(node.class)
          end
        end
        names
      end
    end
  end
end
